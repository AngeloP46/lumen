import Foundation

/// Bakes tone curves + HSL mixer + colour grading into one 3D LUT so the GPU applies them in a single pass.
enum ColorCube {
    static let dim = 48

    private static let centers: [Float] = [0, 30, 60, 120, 180, 240, 275, 320]
    private static let halfWidths: [Float] = [40, 35, 40, 60, 50, 50, 45, 45]

    static func make(curves: ToneCurves, hsl: HSLSettings, grading: ColorGrading) -> Data {
        let n = dim
        let useCurves = !curves.isNeutral
        let lm = ToneCurves.lut(for: curves.master)
        let lr = ToneCurves.lut(for: curves.red)
        let lg = ToneCurves.lut(for: curves.green)
        let lb = ToneCurves.lut(for: curves.blue)
        let useHSL = !hsl.isNeutral
        let useGrade = !grading.isNeutral

        let tS = zoneTint(grading.shadows)
        let tM = zoneTint(grading.midtones)
        let tH = zoneTint(grading.highlights)
        let pivot = Float(0.5 + grading.balance / 100 * 0.25)
        let soft = Float(0.2 + grading.blending / 100 * 0.3)

        var out = [Float](repeating: 0, count: n * n * n * 4)
        let inv = 1 / Float(n - 1)
        var i = 0
        for bi in 0..<n {
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
                    if useHSL {
                        let adjusted = adjustHSL(r, g, b, hsl)
                        r = adjusted.0
                        g = adjusted.1
                        b = adjusted.2
                    }
                    if useGrade {
                        let y: Float = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        let wS: Float = 1 - smooth(pivot - soft, pivot, y)
                        let wH: Float = smooth(pivot, pivot + soft, y)
                        let wM: Float = max(0, 1 - wS - wH)
                        let lum: Float = wS * tS.l + wM * tM.l + wH * tH.l
                        r += wS * tS.r + wM * tM.r + wH * tH.r + lum
                        g += wS * tS.g + wM * tM.g + wH * tH.g + lum
                        b += wS * tS.b + wM * tM.b + wH * tH.b + lum
                    }

                    out[i] = min(max(r, 0), 1)
                    out[i + 1] = min(max(g, 0), 1)
                    out[i + 2] = min(max(b, 0), 1)
                    out[i + 3] = 1
                    i += 4
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

    private static func zoneTint(_ z: GradeZone) -> (r: Float, g: Float, b: Float, l: Float) {
        let c = hslToRGB(Float(z.hue), 1, 0.5)
        let luma: Float = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        let k = Float(z.sat / 100) * 0.35
        return ((c.0 - luma) * k, (c.1 - luma) * k, (c.2 - luma) * k, Float(z.lum / 100) * 0.2)
    }

    private static func adjustHSL(_ r: Float, _ g: Float, _ b: Float, _ s: HSLSettings) -> (Float, Float, Float) {
        let (h, sat, l) = rgbToHSL(r, g, b)
        let gate = min(1, sat / 0.12)   // leave neutral greys alone
        guard gate > 0 else { return (r, g, b) }
        var dh: Float = 0
        var ds: Float = 0
        var dl: Float = 0
        for i in 0..<8 {
            let band = s.bands[i]
            if band == HSLBand() { continue }
            var d = abs(h - centers[i])
            if d > 180 { d = 360 - d }
            let w0 = max(0, 1 - d / halfWidths[i])
            let w = w0 * w0 * (3 - 2 * w0)
            dh += w * Float(band.hue) * 0.3
            ds += w * Float(band.sat) / 100
            dl += w * Float(band.lum) / 100
        }
        var h2 = h + dh * gate
        if h2 < 0 { h2 += 360 }
        if h2 >= 360 { h2 -= 360 }
        let s2 = min(max(sat * (1 + ds * gate), 0), 1)
        let l2 = min(max(l + dl * 0.25 * gate, 0), 1)
        return hslToRGB(h2, s2, l2)
    }

    private static func rgbToHSL(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        if d < 1e-6 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Float
        if mx == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    private static func hslToRGB(_ h: Float, _ s: Float, _ l: Float) -> (Float, Float, Float) {
        if s < 1e-6 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hk = h / 360
        func channel(_ t0: Float) -> Float {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hk + 1.0 / 3), channel(hk), channel(hk - 1.0 / 3))
    }
}
