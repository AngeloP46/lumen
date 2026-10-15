import Foundation
import CoreImage

/// One-tap "Auto" (rewritten 15 Oct 2026): every value comes from this photo's own pixels, nothing is a fixed
/// amount added to every photo.
/// - Exposure meters the subject when Vision finds one (else a centre-weighted average) and respects the scene's
///   key: a bright scene that is not clipping stays bright, a dark scene with light sources stays dark.
/// - Highlights / Shadows / Whites / Blacks move only as far as the measured tones need, and in HDR the
///   highlights above SDR white that the screen can show are left alone.
/// - Contrast follows the tonal spread (flat gets more, already contrasty gets none), Vibrance the existing
///   colour (muted gets more, colourful or black-and-white gets none). Clarity is no longer touched.
/// Edge cases: missing / non-finite / tiny stats leave the photo unchanged; black, white, flat and single-colour
/// photos get bounded, gentle values; an implausible subject (too small, too big) falls back to centre weighting.
extension EditSession {
    /// The fields Auto sets (and the Auto button restores).
    static let autoKeys: [WritableKeyPath<EditSettings, Double>] =
        [\.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks, \.vibrance]

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
        if ev > 0 && top > 0.5 * white { ev *= 0.5 }            // dark with bright lights: night/low key, keep it dark
        if ev > 0 { ev = min(ev, max(0, log2(white * 1.6 / max(top, 1e-4)))) }   // don't blow the brightest parts out
        if median < 0.002 { ev = min(ev, 1.5) }                  // nearly black frame: don't lift sensor noise into grey
        ev = max(-2, min(2, ev))
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

        for key in autoKeys where !s[keyPath: key].isFinite { s[keyPath: key] = current[keyPath: key] }
        return s
    }
}
