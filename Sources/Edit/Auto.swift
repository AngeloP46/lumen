import Foundation
import CoreImage

/// One-tap "Auto" (rewritten 15 Oct 2026): every value comes from this photo's own pixels, nothing is a fixed
/// amount added to every photo.
/// - Exposure meters the subject when Vision finds one (else a centre-weighted average) and respects the scene's
///   key: a bright scene that is not clipping stays bright, a dark scene with light sources stays dark. Brightening is
///   shared (25 Oct): Exposure as far as the bright end allows, Brightness (mid-tones only) the rest.
/// - Highlights / Shadows / Whites / Blacks move only as far as the measured tones need, and in HDR the
///   highlights above SDR white that the screen can show are left alone.
/// - Contrast follows the tonal spread (flat gets more, already contrasty gets none), Vibrance the existing
///   colour (muted gets more, colourful or black-and-white gets none). Clarity is no longer touched.
/// - White balance: finds the photo's near-neutral areas (greys, whites, tarmac, cloud) and corrects most of
///   their colour cast, not all of it, so golden hour stays warm; photos with too little neutral to go on
///   (one colour filling the frame, a sunset) and black-and-white keep their white balance.
/// Edge cases: missing / non-finite / tiny stats leave the photo unchanged; black, white, flat and single-colour
/// photos get bounded, gentle values; an implausible subject (too small, too big) falls back to centre weighting.
extension EditSession {
    /// The fields Auto sets (and the Auto button restores).
    static let autoKeys: [WritableKeyPath<EditSettings, Double>] =
        [\.exposure, \.brightness, \.contrast, \.highlights, \.shadows, \.whites, \.blacks, \.vibrance, \.temperature, \.tint]

    func autoSettings(source: ImageSource, current: EditSettings) -> EditSettings {
        Self.autoSettings(grid: source.stats, subject: autoSubjectWeights(source), current: current)
    }

    /// Vision's subject (only if already found, see `ensureSubject`), sampled on the stats grid (top row first).
    func autoSubjectWeights(_ source: ImageSource) -> [Float]? {
        let g = source.stats
        guard g.width > 0, g.height > 0, let subject = source.cachedMask(Self.aiSubject) else { return nil }
        let small = Self.fit(subject, to: CGRect(x: 0, y: 0, width: g.width, height: g.height))
        var px = [Float](repeating: 0, count: g.width * g.height * 4)
        px.withUnsafeMutableBytes { p in
            ctx.render(small, toBitmap: p.baseAddress!, rowBytes: g.width * 16, bounds: small.extent, format: .RGBAf, colorSpace: nil)
        }
        return stride(from: 0, to: px.count, by: 4).map { min(max(px[$0], 0), 1) }
    }

    static func autoSettings(grid g: PixelGrid, subject: [Float]?, current: EditSettings) -> EditSettings {
        var s = current
        let n = g.width * g.height
        guard n >= 16, g.data.count >= n * 4 else { return s }

        // luminance and saturation per cell; anything non-finite is skipped
        var lum: [Float] = [], sat: [Float] = [], centre: [Float] = [], subj: [Float] = []
        var rgbCells: [SIMD3<Float>] = []
        lum.reserveCapacity(n)
        let useSubject: Bool = {
            guard let subject, subject.count == n else { return false }
            let cover = subject.reduce(0, +) / Float(n)
            return cover > 0.03 && cover < 0.7     // a speck or nearly the whole frame is no guide
        }()
        for y in 0..<g.height {
            for x in 0..<g.width {
                let i = y * g.width + x
                let r = g.data[i * 4], gr = g.data[i * 4 + 1], b = g.data[i * 4 + 2]
                guard r.isFinite, gr.isFinite, b.isFinite else { continue }
                let Y = max(0.22897 * r + 0.69174 * gr + 0.07929 * b, 1e-5)
                lum.append(Y)
                rgbCells.append(SIMD3(max(r, 1e-5), max(gr, 1e-5), max(b, 1e-5)))
                let mx = max(r, gr, b), mn = min(r, gr, b)
                sat.append(mx > 1e-4 ? (mx - max(mn, 0)) / mx : 0)
                let dx = (Float(x) + 0.5) / Float(g.width) - 0.5, dy = (Float(y) + 0.5) / Float(g.height) - 0.5
                centre.append(1 + 1.5 * exp(-(dx * dx + dy * dy) / 0.08))
                subj.append(useSubject ? subject![i] : 0)
            }
        }
        guard lum.count >= 16 else { return s }

        func percentile(_ v: [Float], _ w: [Float]?, _ p: Float) -> Float {
            let order = v.indices.sorted { v[$0] < v[$1] }
            let total = w.map { $0.reduce(0, +) } ?? Float(v.count)
            guard total > 0 else { return v[order[order.count / 2]] }
            var acc: Float = 0
            for i in order {
                acc += w?[i] ?? 1
                if acc >= total * p { return v[i] }
            }
            return v[order.last!]
        }
        let median = percentile(lum, nil, 0.5)
        let low = percentile(lum, nil, 0.03), high = percentile(lum, nil, 0.985), top = percentile(lum, nil, 0.997)

        // white level: SDR white, or in HDR what the HDR range allows (default 2 stops above white)
        let white: Float = s.hdr ? Float(exp2(max(s.hdrStops, 0.5))) : 1

        // --- Exposure: meter the subject (or centre-weighted), keep the scene's key
        var meter = percentile(lum, centre, 0.5)
        if useSubject {
            let inSubject = percentile(lum, subj, 0.5)
            meter = exp(0.65 * log(inSubject) + 0.35 * log(meter))
        }
        var ev = log2(0.16 / max(meter, 1e-4)) * 0.75
        if ev < 0 && high < white * 0.98 { ev *= 0.4 }          // bright but not clipping: a high-key scene, keep it bright
        // dark with bright lights (night, low key): keep it dark. Lights are small and the rest is dark: before 25 Oct any
        // photo whose brightest 0.3 % passed half white counted, so a dull day under a bright sky was lifted only half way
        let brightShare = Float(lum.filter { $0 > 0.3 * white }.count) / Float(lum.count)
        let lowKey = ev > 0 && top > 0.5 * white && brightShare < 0.05 && median < 0.04
        if lowKey { ev *= 0.5 }
        if median < 0.002 { ev = min(ev, 1.5) }                  // nearly black frame: don't lift sensor noise into grey
        ev = max(-2, min(2, ev))
        // Brightening is shared (owner, 25 Oct: pushed with Exposure a dull photo looked over-exposed): Exposure only as far
        // as the bright end allows (the brightest parts not blown, the 98.5th percentile below the highlight shoulder at
        // 0.85), Brightness the rest, which lifts the mid-tones and leaves the highlights. A low-key scene keeps its dark.
        s.brightness = 0
        if ev > 0 {
            let room = max(0, min(log2(white * 1.6 / max(top, 1e-4)), log2(white * 0.85 / max(high, 1e-4))))
            let rest = ev - min(ev, room)
            ev = min(ev, room)
            if rest > 0.05 && !lowKey {
                // how much of Brightness reaches the metered tone (the kernel's mid-tone weight, at that tone after Exposure)
                func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
                let bb = log2(max(meter * exp2(ev), 1e-5) / 0.18)
                let reach = max(smooth(-7.5, -2.5, bb) * (1 - smooth(-0.5, 2.4, bb)), 0.35)
                s.brightness = Double(min(100, rest / reach * 100)).rounded()
            }
        }
        s.exposure = (Double(ev) * 20).rounded() / 20
        let k = exp2(Float(s.exposure))
        let h = high * k, l = low * k

        // --- Highlights / Whites (highlights against the white level; whites against SDR white)
        if h > 0.85 * white { s.highlights = -Double(min(80, 20 + (h / white - 0.85) * 250)) }
        else if h > 0.6 * white { s.highlights = -Double((h / white - 0.6) * 40) }
        else { s.highlights = 0 }
        s.whites = h < 0.65 ? Double(min(40, (0.65 - h) * 80)) : 0
        // --- Shadows / Blacks
        if l < 0.02 { s.shadows = Double(min(70, 15 + (0.02 - l) * 2500)) }
        else if l < 0.05 { s.shadows = Double((0.05 - l) * 300) }
        else { s.shadows = 0 }
        s.blacks = l > 0.012 ? -Double(min(35, (l - 0.012) * 700)) : 0

        // --- Contrast from the tonal spread (stops between the 5th and 95th percentile)
        let spread = log2(max(percentile(lum, nil, 0.95), 1e-4) / max(percentile(lum, nil, 0.05), 1e-4))
        var contrast = (6.5 - spread) * 6
        if s.shadows > 30 || s.highlights < -40 { contrast = min(contrast, 5) }   // wide-range scene: tone it, don't steepen it
        s.contrast = Double(max(-10, min(25, contrast)).rounded())

        // --- Vibrance from the colour already there (mid-tones only; B&W and near-grey photos get none)
        let mids = sat.indices.filter { lum[$0] > 0.01 && lum[$0] < 0.9 * white }.map { sat[$0] }
        let colour = mids.count >= 8 ? percentile(mids, nil, 0.5) : 0
        s.vibrance = (s.blackAndWhite || colour < 0.03) ? 0 : Double(max(0, min(25, (0.32 - colour) * 110)).rounded())

        // --- White balance (stats are the photo as decoded, so this is absolute: tapping Auto twice gives the same)
        if !s.blackAndWhite, let wb = autoWhiteBalance(lum: lum, rgb: rgbCells, white: white) {
            s.temperature = wb.0; s.tint = wb.1
        }

        for key in autoKeys where !s[keyPath: key].isFinite { s[keyPath: key] = current[keyPath: key] }
        return s
    }

    /// Temperature / tint (the develop kernel's units) that take most of the cast off the near-neutral areas,
    /// or nil when the photo gives too little to go on.
    static func autoWhiteBalance(lum: [Float], rgb: [SIMD3<Float>], white: Float) -> (Double, Double)? {
        // log chroma per cell: blue vs red, and green vs the red/blue average
        var ab: [Float] = [], gm: [Float] = []
        for (i, c) in rgb.enumerated() where lum[i] > 0.03 && lum[i] < 0.9 * white {
            let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
            guard (mx - mn) / mx < 0.35 else { continue }        // clearly coloured things are not evidence
            ab.append(log2(c.z / c.x)); gm.append(log2(c.y / (c.x * c.z).squareRoot()))
        }
        guard ab.count >= max(8, lum.count / 20) else { return nil }   // under 5 % near-neutral: leave it
        func median(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
        var cab = median(ab), cgm = median(gm)
        for _ in 0..<2 {   // keep the cells that agree with the estimate (drops coloured surfaces that slipped in)
            let keep = ab.indices.filter { abs(ab[$0] - cab) < 0.25 && abs(gm[$0] - cgm) < 0.25 }
            guard keep.count >= 8 else { break }
            cab = median(keep.map { ab[$0] }); cgm = median(keep.map { gm[$0] })
        }
        // the picker's maths for a spot of this colour (r = 1, b = 2^ab, g = 2^gm * sqrt(b))
        let r = 1.0, b = Double(exp2(cab)), g = Double(exp2(cgm)) * b.squareRoot()
        let t = log2(b / r) / 1.2
        let n = -log2(r * exp2(0.6 * t) / g) / 0.4
        // most of the way, less for a very strong cast (likely deliberate light), and within sensible limits
        let strength = abs(cab) > 1.2 ? 0.3 : 0.6
        let temp = min(max(t * 100 * strength, -30), 30).rounded()
        let tint = min(max(n * 100 * strength, -20), 20).rounded()
        guard temp.isFinite, tint.isFinite else { return nil }
        return (temp, tint)
    }
}
