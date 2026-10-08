import Foundation

/// Bakes tone curves + HSL mixer + colour grading (+ black & white) into one 3D LUT so the GPU applies
/// them in a single pass. Input and output are gamma-encoded Display P3. The HSL mixer and the grading
/// work in OkLab (perceptual), which keeps hue shifts and saturation moves looking natural.
enum ColorCube {
    static let dim = 48

    // Band centres as OkLab hue angles (radians): red, orange, yellow, green, aqua, blue, purple, magenta.
    private static let bandHue: [Float] = [29, 55, 100, 142, 195, 264, 300, 345].map { $0 * .pi / 180 }

    static func make(curves: ToneCurves, hsl: HSLSettings, grading: ColorGrading, blackAndWhite: Bool) -> Data {
        let n = dim
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
        let mid = Float(0.5 - grading.balance / 100 * 0.25)
        let width = Float(0.15 + grading.blending / 100 * 0.5)

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
                            var chroma = (lab.1 * lab.1 + lab.2 * lab.2).squareRoot()
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
                            if useGrade && !blackAndWhite {
                                let wS: Float = 1 - smooth(mid - width, mid + width * 0.25, lab.0)
                                let wH: Float = smooth(mid - width * 0.25, mid + width, lab.0)
                                let wM: Float = max(0, 1 - wS - wH)
                                a += wS * tS.a + wM * tM.a + wH * tH.a
                                bb += wS * tS.b + wM * tM.b + wH * tH.b
                                lab.0 += wS * tS.l + wM * tM.l + wH * tH.l
                            }
                            let lin = Ok.fromLab(lab.0, a, bb)
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

    private static func zoneTint(_ z: GradeZone) -> (a: Float, b: Float, l: Float) {
        let h = Float(z.hue) * .pi / 180
        let k = Float(z.sat / 100) * 0.08
        return (k * cos(h), k * sin(h), Float(z.lum / 100) * 0.15)
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
}
