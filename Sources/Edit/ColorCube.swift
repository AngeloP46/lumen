import Foundation

/// Bakes tone curves + HSL mixer + colour grading (+ black & white) into one 3D LUT so the GPU applies
/// them in a single pass. Input and output are gamma-encoded Display P3. The HSL mixer and the grading
/// work in OkLab (perceptual), which keeps hue shifts and saturation moves looking natural.
enum ColorCube {
    static let dim = 48

    // Band centres as OkLab hue angles (radians): red, orange, yellow, green, aqua, blue, purple, magenta.
    private static let bandHue: [Float] = [29, 55, 100, 142, 195, 264, 300, 345].map { $0 * .pi / 180 }

    static func make(curves: ToneCurves, hsl: HSLSettings, grading: ColorGrading, blackAndWhite: Bool,
                     processingVersion: Int = 2) -> Data {
        let n = dim
        let modern = processingVersion >= 2
        let useCurves = !curves.isNeutral
        let lm = ToneCurves.lut(for: curves.master)
        let lr = ToneCurves.lut(for: curves.red)
        let lg = ToneCurves.lut(for: curves.green)
        let lb = ToneCurves.lut(for: curves.blue)
        let useHSL = !hsl.isNeutral
        let useGrade = !grading.isNeutral
        let useLab = useHSL || useGrade || blackAndWhite

        let tS = zoneTint(grading.shadows)
        let tM = zoneTint(grading.midtones)
        let tH = zoneTint(grading.highlights)
        let tG = zoneTint(grading.global)
        let mid = Float(0.5 - grading.balance / 100 * 0.25)
        let width = Float(0.15 + grading.blending / 100 * 0.5)
        let hasGradeLuminance = [grading.shadows, grading.midtones, grading.highlights, grading.global].contains { $0.lum != 0 }
        let gradeLuminance = modern && hasGradeLuminance
            ? gradeLuminanceTable(mid: mid, width: width, shadows: tS.l, midtones: tM.l, highlights: tH.l, global: tG.l)
            : []

        let hueD = hsl.bands.map { Float($0.hue) / 100 * 0.5 }
        let satD = hsl.bands.map { Float($0.sat) / 100 }
        let lumD = hsl.bands.map { Float($0.lum) / 100 * 0.25 }

        let count = n * n * n * 4
        var out = [Float](repeating: 0, count: count)
        let inv = 1 / Float(n - 1)
        out.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { bi in
                var i = bi * n * n * 4
                for gi in 0..<n {
                    for ri in 0..<n {
                        var r = Float(ri) * inv
                        var g = Float(gi) * inv
                        var b = Float(bi) * inv

                        if useCurves {
                            r = sample(lr, sample(lm, r))
                            g = sample(lg, sample(lm, g))
                            b = sample(lb, sample(lm, b))
                        }
                        if useLab {
                            let lr_ = Ok.decode(r), lg_ = Ok.decode(g), lb_ = Ok.decode(b)
                            var lab = Ok.toLab(lr_, lg_, lb_)
                            let originalLab = lab
                            var chroma = (lab.1 * lab.1 + lab.2 * lab.2).squareRoot()
                            let originalChroma = blackAndWhite ? 0 : chroma
                            var hue = atan2(lab.2, lab.1)
                            if useHSL {
                                let w = bandWeights(hue)
                                var dh: Float = 0, ds: Float = 0, dl: Float = 0
                                for k in 0..<8 where w[k] > 0 {
                                    dh += w[k] * hueD[k]
                                    ds += w[k] * satD[k]
                                    dl += w[k] * lumD[k]
                                }
                                let gate = min(chroma / 0.1, 1)
                                hue += dh * gate
                                chroma *= max(1 + ds, 0)
                                lab.0 += dl * gate * lab.0.squareRoot()
                            }
                            if blackAndWhite {
                                chroma = 0
                            }
                            var a = chroma * cos(hue)
                            var bb = chroma * sin(hue)
                            if useGrade && (modern || !blackAndWhite) {
                                let wS: Float = 1 - smooth(mid - width, mid + width * 0.25, lab.0)
                                let wH: Float = smooth(mid - width * 0.25, mid + width, lab.0)
                                let wM: Float = max(0, 1 - wS - wH)
                                // Keep black and white endpoints when adding a tint, including to a B&W conversion.
                                // Version 1 retains its original behaviour for already-saved edits.
                                let fade: Float = modern ? smooth(0, 0.12, lab.0) * (1 - smooth(0.88, 1, lab.0)) : 1
                                a += (wS * tS.a + wM * tM.a + wH * tH.a + tG.a) * fade
                                bb += (wS * tS.b + wM * tM.b + wH * tH.b + tG.b) * fade
                                if modern {
                                    if !gradeLuminance.isEmpty { lab.0 = sample(gradeLuminance, lab.0) }
                                } else {
                                    lab.0 += wS * tS.l + wM * tM.l + wH * tH.l + tG.l
                                }
                            }
                            let changed = abs(lab.0 - originalLab.0) > 1e-7 || abs(a - originalLab.1) > 1e-7
                                || abs(bb - originalLab.2) > 1e-7
                            let lin = modern && changed
                                ? Ok.gamutCompressed(lab.0, a, bb, originalChroma: originalChroma)
                                : Ok.fromLab(lab.0, a, bb)
                            r = Ok.encode(lin.0)
                            g = Ok.encode(lin.1)
                            b = Ok.encode(lin.2)
                        }

                        base[i] = min(max(r, 0), 1)
                        base[i + 1] = min(max(g, 0), 1)
                        base[i + 2] = min(max(b, 0), 1)
                        base[i + 3] = 1
                        i += 4
                    }
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: Helpers

    private static func sample(_ lut: [Float], _ v: Float) -> Float {
        let x = min(max(v, 0), 1) * Float(lut.count - 1)
        let i0 = Int(x)
        let i1 = min(i0 + 1, lut.count - 1)
        let f = x - Float(i0)
        return lut[i0] * (1 - f) + lut[i1] * f
    }

    private static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / max(e1 - e0, 1e-6), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// One endpoint-preserving lightness curve for the whole grade. The same scale is used for every
    /// level, so strong overlapping zones keep their shape without reversing the order of tones.
    /// Linear interpolation of this sampled curve retains the lower slope bound between samples too.
    private static func gradeLuminanceTable(mid: Float, width: Float, shadows: Float, midtones: Float,
                                            highlights: Float, global: Float) -> [Float] {
        let n = 1024
        let inv = 1 / Float(n - 1)
        var delta = [Float](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let L = Float(i) * inv
            let wS = 1 - smooth(mid - width, mid + width * 0.25, L)
            let wH = smooth(mid - width * 0.25, mid + width, L)
            let wM = max(0, 1 - wS - wH)
            let fade = smooth(0, 0.12, L) * (1 - smooth(0.88, 1, L))
            let d = (wS * shadows + wM * midtones + wH * highlights + global) * fade
            delta[i] = d.isFinite ? d : 0
        }
        var lowestSlope: Float = 0
        for i in 1..<n { lowestSlope = min(lowestSlope, (delta[i] - delta[i - 1]) / inv) }
        let scale: Float = lowestSlope < -0.9 ? -0.9 / lowestSlope : 1
        return delta.enumerated().map { i, d in min(max(Float(i) * inv + d * scale, 0), 1) }
    }

    /// Cosine blend between the two neighbouring band centres.
    private static func bandWeights(_ h: Float) -> [Float] {
        var w = [Float](repeating: 0, count: 8)
        let tau = Float.pi * 2
        func wrap(_ x: Float) -> Float {
            var v = x.truncatingRemainder(dividingBy: tau)
            if v < 0 { v += tau }
            return v
        }
        for i in 0..<8 {
            let a = bandHue[i]
            let b = bandHue[(i + 1) % 8]
            let span = wrap(b - a)
            let d = wrap(h - a)
            if d <= span {
                let t = d / span
                let s = 0.5 - 0.5 * cos(t * .pi)
                w[i] += 1 - s
                w[(i + 1) % 8] += s
                break
            }
        }
        return w
    }

    /// The wheel shows ordinary HSV hues, so the tint direction is taken from that same colour in OkLab.
    private static func zoneTint(_ z: GradeZone) -> (a: Float, b: Float, l: Float) {
        let (r, g, b) = hsvToRGB(Float(z.hue) / 360, 1, 1)
        let lab = Ok.toLab(Ok.decode(r), Ok.decode(g), Ok.decode(b))
        let c = max((lab.1 * lab.1 + lab.2 * lab.2).squareRoot(), 1e-4)
        let k = Float(z.sat / 100) * 0.09
        return (lab.1 / c * k, lab.2 / c * k, Float(z.lum / 100) * 0.15)
    }

    static func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
        let hh = (h - floor(h)) * 6
        let i = Int(hh) % 6
        let f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

/// OkLab conversions for linear Display P3 (the app's working primaries).
enum Ok {
    @inline(__always) static func decode(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }
    @inline(__always) static func encode(_ v: Float) -> Float {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055
    }
    static func toLab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let l = cbrtf(max(0.481327291 * r + 0.462067912 * g + 0.056495603 * b, 0))
        let m = cbrtf(max(0.228838101 * r + 0.653234400 * g + 0.117954413 * b, 0))
        let s = cbrtf(max(0.083986018 * r + 0.224272789 * g + 0.692220839 * b, 0))
        return (0.210454255 * l + 0.793617785 * m - 0.004072047 * s,
                1.977998495 * l - 2.428592205 * m + 0.450593710 * s,
                0.025904037 * l + 0.782771766 * m - 0.808675766 * s)
    }
    static func fromLab(_ L: Float, _ a: Float, _ b: Float) -> (Float, Float, Float) {
        var l = L + 0.396337792 * a + 0.215803758 * b
        var m = L - 0.105561342 * a - 0.063854175 * b
        var s = L - 0.089484182 * a - 1.291485538 * b
        l = l * l * l; m = m * m * m; s = s * s * s
        return (3.128110530 * l - 2.257075019 * m + 0.129304789 * s,
                -1.091128161 * l + 2.413266762 * m - 0.322168171 * s,
                -0.026013650 * l - 0.508027649 * m + 1.533316682 * s)
    }

    /// A soft chroma shoulder in OkLab, at fixed lightness and hue. Unlike clipping RGB channels, this keeps
    /// differences between very colourful shades. The same search and knee are used by the develop kernel.
    static func gamutCompressed(_ lightness: Float, _ a: Float, _ b: Float,
                                originalChroma: Float = 0) -> (Float, Float, Float) {
        guard lightness.isFinite, a.isFinite, b.isFinite else { return (0, 0, 0) }
        let L = min(max(lightness, 0), 1)
        let C = hypotf(a, b)
        if C < 1e-5 || L <= 0 || L >= 1 {
            let y = L * L * L
            return (y, y, y)
        }
        let input = fromLab(L, a, b)
        // Below the shoulder (or reducing chroma), no boundary search is necessary. Testing 1.25 C
        // is equivalent to testing that C is at most 80% of the gamut boundary along this ray.
        if inGamut(input) && (C <= originalChroma || inGamut(fromLab(L, a * 1.25, b * 1.25))) { return input }
        let ah = a / C, bh = b / C
        var lo: Float = 0, hi: Float = 1
        for _ in 0..<12 {
            let mid = (lo + hi) * 0.5
            let rgb = fromLab(L, ah * mid, bh * mid)
            if rgb.0 >= 0 && rgb.0 <= 1 && rgb.1 >= 0 && rgb.1 <= 1 && rgb.2 >= 0 && rgb.2 <= 1 {
                lo = mid
            } else {
                hi = mid
            }
        }
        // Raising the knee to the input chroma makes a tiny adjustment continuous at zero, including on
        // already-vivid pixels. An untouched colour band bypasses this operation at the call site too.
        let knee = max(lo * 0.8, min(max(originalChroma, 0), lo))
        let width = lo - knee
        let compressed: Float
        if width < 1e-6 {
            compressed = min(C, lo)
        } else {
            compressed = C <= knee ? C : knee + width * (1 - expf(-(C - knee) / width))
        }
        return fromLab(L, ah * compressed, bh * compressed)
    }

    private static func inGamut(_ rgb: (Float, Float, Float)) -> Bool {
        rgb.0 >= 0 && rgb.0 <= 1 && rgb.1 >= 0 && rgb.1 <= 1 && rgb.2 >= 0 && rgb.2 <= 1
    }
}

/// Relative warm/cool and green/magenta corrections around the decoded image's white balance. Version 2
/// applies the ICC linear Bradford cone transform, not independent display RGB channel gains. Slider units
/// remain -100...100; these relative controls deliberately do not claim to be a Kelvin measurement.
enum RelativeWhiteBalance {
    typealias RGB = (Float, Float, Float)

    static func apply(_ rgb: RGB, temperature: Double, tint: Double, processingVersion: Int = 2) -> RGB {
        guard temperature.isFinite, tint.isFinite else { return rgb }
        if temperature == 0 && tint == 0 { return rgb }
        let t = Float(temperature / 100), n = Float(tint / 100)
        let gain: RGB = (exp2f(0.6 * t), exp2f(-0.4 * n), exp2f(-0.6 * t))
        let oldY = luminance(rgb)
        let result: RGB
        if processingVersion < 2 {
            result = (rgb.0 * gain.0, rgb.1 * gain.1, rgb.2 * gain.2)
        } else {
            let whiteY = max(luminance(gain), 1e-6)
            let white = toCone((gain.0 / whiteY, gain.1 / whiteY, gain.2 / whiteY))
            let d65 = toCone((1, 1, 1))
            let cone = toCone(rgb)
            result = fromCone((cone.0 * white.0 / d65.0, cone.1 * white.1 / d65.1, cone.2 * white.2 / d65.2))
        }
        let scale = oldY / max(luminance(result), 1e-6)
        return (result.0 * scale, result.1 * scale, result.2 * scale)
    }

    /// The inverse of `apply` for a sampled neutral patch. The return value is bounded to the controls;
    /// callers can impose smaller Auto limits or round for display after solving.
    static func solve(_ rgb: RGB, processingVersion: Int = 2) -> (temperature: Double, tint: Double) {
        guard rgb.0.isFinite, rgb.1.isFinite, rgb.2.isFinite else { return (0, 0) }
        let sample: RGB = (max(rgb.0, 1e-5), max(rgb.1, 1e-5), max(rgb.2, 1e-5))
        let white: RGB
        if processingVersion < 2 {
            white = (1 / sample.0, 1 / sample.1, 1 / sample.2)
        } else {
            let cone = toCone(sample), d65 = toCone((1, 1, 1))
            // Adapt sample's cone response back to neutral D65. A common scale has no chromatic effect.
            white = fromCone((d65.0 * d65.0 / max(cone.0, 1e-6),
                              d65.1 * d65.1 / max(cone.1, 1e-6),
                              d65.2 * d65.2 / max(cone.2, 1e-6)))
        }
        let r = Double(max(white.0, 1e-6)), g = Double(max(white.1, 1e-6)), b = Double(max(white.2, 1e-6))
        let t = log2(r / b) / 1.2 * 100
        let n = -log2(g / sqrt(r * b)) / 0.4 * 100
        return (min(max(t, -100), 100), min(max(n, -100), 100))
    }

    private static func luminance(_ c: RGB) -> Float { 0.22897 * c.0 + 0.69174 * c.1 + 0.07929 * c.2 }

    private static func toCone(_ c: RGB) -> RGB {
        let x = 0.4865709486 * c.0 + 0.2656676932 * c.1 + 0.1982172852 * c.2
        let y = 0.2289745641 * c.0 + 0.6917385218 * c.1 + 0.0792869141 * c.2
        let z = 0.0451133819 * c.1 + 1.0439443689 * c.2
        return (0.8951 * x + 0.2664 * y - 0.1614 * z,
                -0.7502 * x + 1.7135 * y + 0.0367 * z,
                0.0389 * x - 0.0685 * y + 1.0296 * z)
    }

    private static func fromCone(_ c: RGB) -> RGB {
        let x = 0.9869929055 * c.0 - 0.1470542564 * c.1 + 0.1599626517 * c.2
        let y = 0.4323052697 * c.0 + 0.5183602715 * c.1 + 0.0492912282 * c.2
        let z = -0.0085286646 * c.0 + 0.0400428217 * c.1 + 0.9684866958 * c.2
        return (2.4934969119 * x - 0.9313836179 * y - 0.4027107845 * z,
                -0.8294889696 * x + 1.7626640603 * y + 0.0236246858 * z,
                0.0358458302 * x - 0.0761723893 * y + 0.9568845240 * z)
    }
}
