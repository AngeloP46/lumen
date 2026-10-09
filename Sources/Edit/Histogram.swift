import CoreGraphics
import CoreImage
import Foundation

struct HistogramData {
    var r: [Float]
    var g: [Float]
    var b: [Float]
    var luma: [Float]
    /// Share of pixels brighter than SDR white (0...1); only set while HDR is on.
    var hdrShare: Float = 0
    /// HDR (Lightroom style): the left `sdrFraction` of the width is the usual SDR scale, the rest one segment per
    /// stop above SDR white (`hdrStops` segments). nil = plain SDR histogram.
    var sdrFraction: Float?
    var hdrStops: Float = 0
    /// Stops above white the screen can show right now (the rest of the HDR zone is dimmed).
    var screenStops: Float = 0
    /// How far above white the brightest part of the photo goes (99.9th percentile), in stops.
    var hdrPeakStops: Float = 0
}

enum Histogram {
    static let bins = 64

    static func compute(_ cg: CGImage) -> HistogramData? {
        let w = 128, h = 128
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { ptr in
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var r = [Float](repeating: 0, count: bins)
        var g = r, b = r, l = r
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let rv = Int(bytes[i]), gv = Int(bytes[i + 1]), bv = Int(bytes[i + 2])
            r[rv * bins / 256] += 1
            g[gv * bins / 256] += 1
            b[bv * bins / 256] += 1
            let y = (rv * 54 + gv * 183 + bv * 19) >> 8
            l[min(y, 255) * bins / 256] += 1
        }
        // Scale by the tallest interior bin so clipped end-spikes don't flatten everything else.
        var peak: Float = 1
        for arr in [r, g, b, l] {
            for i in 1..<(bins - 1) { peak = max(peak, arr[i]) }
        }
        func norm(_ a: [Float]) -> [Float] { a.map { min(1, ($0 / peak).squareRoot()) } }
        return HistogramData(r: norm(r), g: norm(g), b: norm(b), luma: norm(l))
    }

    static let sdrFraction: Float = 0.6

    /// Replaces the colour channels with an HDR histogram of `img` (extended linear): SDR on the left 60 %, then one
    /// segment per stop above white up to `stops`. The luminance histogram (used by the luminance mask) stays SDR.
    /// Read in Display P3 (the working gamut): in sRGB, vivid P3 colours would look "brighter than white".
    static func addHDR(_ h: inout HistogramData, _ img: CIImage, stops: Double, screenStops: Double) {
        let e = img.extent
        guard e.width > 0, e.height > 0, e.width.isFinite, e.height.isFinite,
              let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return }
        let k = 128 / max(e.width, e.height)
        let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), ht = Int(r.height)
        guard w > 0, ht > 0 else { return }
        var buf = [Float](repeating: 0, count: w * ht * 4)
        buf.withUnsafeMutableBytes { p in
            LumenGPU.context.render(small, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: cs)
        }
        let st = Float(max(stops, 1))
        func enc(_ v: Float) -> Float { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        func bin(_ v: Float) -> Int {
            let x = v <= 1 ? sdrFraction * enc(max(v, 0)) : sdrFraction + (1 - sdrFraction) * min(log2(v) / st, 1)
            return min(max(Int(x * Float(bins)), 0), bins - 1)
        }
        var cr = [Float](repeating: 0, count: bins), cg = cr, cb = cr
        var brightest = [Float](); brightest.reserveCapacity(w * ht)
        var over = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let rv = buf[i], gv = buf[i + 1], bv = buf[i + 2]
            cr[bin(rv)] += 1; cg[bin(gv)] += 1; cb[bin(bv)] += 1
            let m = max(rv, gv, bv)
            brightest.append(m)
            if m > 1.02 { over += 1 }
        }
        var peak: Float = 1
        for arr in [cr, cg, cb] { for i in 1..<(bins - 1) { peak = max(peak, arr[i]) } }
        func norm(_ a: [Float]) -> [Float] { a.map { min(1, ($0 / peak).squareRoot()) } }
        brightest.sort()
        let top = brightest.isEmpty ? 0 : brightest[min(brightest.count - 1, Int(Float(brightest.count) * 0.999))]
        h.r = norm(cr); h.g = norm(cg); h.b = norm(cb)
        h.sdrFraction = sdrFraction
        h.hdrStops = st
        h.screenStops = Float(min(max(screenStops, 0), stops))
        h.hdrShare = Float(over) / Float(max(w * ht, 1))
        h.hdrPeakStops = top > 1 ? log2(top) : 0
    }

    /// Share of pixels whose brightest channel is above 1.0 (the HDR zone) in a small extended-linear render.
    static func hdrShare(_ img: CIImage) -> Float {
        let e = img.extent
        guard e.width > 0, e.height > 0, e.width.isFinite, e.height.isFinite,
              let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return 0 }
        let k = 96 / max(e.width, e.height)
        let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return 0 }
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            LumenGPU.context.render(small, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: cs)
        }
        var n = 0
        for i in stride(from: 0, to: buf.count, by: 4) where max(buf[i], buf[i + 1], buf[i + 2]) > 1.02 { n += 1 }
        return Float(n) / Float(w * h)
    }
}
