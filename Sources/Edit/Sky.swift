import CoreImage
import Foundation

/// Sky selection. Apple has no sky-segmentation API, so this is a classical approach: find sky-coloured,
/// smooth pixels touching the top of the frame and grow outwards while colour changes only gradually.
extension EditSession {
    func computeSky(_ source: ImageSource) -> CIImage? {
        let ext = source.extent
        let k = min(1, 448 / max(ext.width, ext.height))
        let small = Self.normalized(source.base.transformed(by: CGAffineTransform(scaleX: k, y: k)))
        let grid = readGrid(small)
        guard let mask = SkyFinder.find(grid) else { return nil }
        let w = grid.width, h = grid.height

        // Mask bytes -> CIImage (row 0 = top), then smooth and scale to the photo.
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { bytes[i] = mask[i] }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        var ci = Self.expandRed(CIImage(cgImage: cg, options: [.colorSpace: NSNull()]))
        ci = Self.blur(ci, 1.6, ci.extent)
        if let m = Self.materialized(ci) { ci = m }
        return Self.fit(ci, to: ext)
    }
}

enum SkyFinder {
    /// Returns a w*h byte mask (255 = sky) or nil when no sky is found.
    static func find(_ g: PixelGrid) -> [UInt8]? {
        let w = g.width, h = g.height
        guard w > 8, h > 8 else { return nil }
        let n = w * h

        // Display-referred colour and brightness.
        var r = [Float](repeating: 0, count: n), gg = r, b = r, y = r
        for i in 0..<n {
            r[i] = Ok.encode(g.data[i * 4])
            gg[i] = Ok.encode(g.data[i * 4 + 1])
            b[i] = Ok.encode(g.data[i * 4 + 2])
            y[i] = 0.2126 * r[i] + 0.7152 * gg[i] + 0.0722 * b[i]
        }
        // Gradient magnitude of brightness.
        var grad = [Float](repeating: 0, count: n)
        for yy in 1..<(h - 1) {
            for xx in 1..<(w - 1) {
                let i = yy * w + xx
                let gx = y[i + 1] - y[i - 1]
                let gy = y[i + w] - y[i - w]
                grad[i] = (gx * gx + gy * gy).squareRoot()
            }
        }

        func sat(_ i: Int) -> Float {
            let mx = max(r[i], gg[i], b[i]), mn = min(r[i], gg[i], b[i])
            return mx > 0.001 ? (mx - mn) / mx : 0
        }
        func skyish(_ i: Int) -> Bool {
            let rr = r[i], g_ = gg[i], bb = b[i], yv = y[i], s = sat(i)
            if g_ > rr + 0.05 && g_ > bb - 0.01 { return false }          // foliage
            if bb > rr + 0.03 && bb >= g_ - 0.03 && yv > 0.18 { return true }  // blue sky
            if yv > 0.55 && s < 0.25 { return true }                       // cloud, haze, overcast
            if abs(rr - bb) < 0.07 && s < 0.14 && yv > 0.28 { return true } // grey overcast
            if rr > bb + 0.04 && yv > 0.45 && s < 0.7 { return true }      // sunrise / sunset glow
            return false
        }
        func dist(_ i: Int, _ j: Int) -> Float {
            let dr = r[i] - r[j], dg = gg[i] - gg[j], db = b[i] - b[j]
            return (dr * dr + dg * dg + db * db).squareRoot()
        }

        // Seeds along the top of the frame.
        var mask = [UInt8](repeating: 0, count: n)
        var queue = [Int]()
        queue.reserveCapacity(n)
        let seedRows = max(2, h / 10)
        for yy in 0..<seedRows {
            for xx in 0..<w {
                let i = yy * w + xx
                if skyish(i) && grad[i] < 0.12 && mask[i] == 0 {
                    mask[i] = 255
                    queue.append(i)
                }
            }
        }
        guard queue.count > w / 6 else { return nil }

        // Grow while the colour changes only gradually.
        var head = 0
        let step: Float = 0.055
        while head < queue.count {
            let p = queue[head]; head += 1
            let px = p % w, py = p / w
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = px + dx, ny = py + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let q = ny * w + nx
                if mask[q] != 0 { continue }
                let d = dist(p, q)
                let ok = (skyish(q) && d < step && grad[q] < 0.22) || (d < step * 0.45 && y[q] > 0.2 && gg[q] <= r[q] + 0.1)
                if ok {
                    mask[q] = 255
                    queue.append(q)
                }
            }
        }
        // A sky that fills almost nothing is probably noise.
        guard queue.count > n / 40 else { return nil }

        // Fill small holes (birds, hot pixels) and drop specks.
        closeHoles(&mask, w, h, maxArea: max(12, n / 400))
        return mask
    }

    private static func closeHoles(_ mask: inout [UInt8], _ w: Int, _ h: Int, maxArea: Int) {
        var seen = [Bool](repeating: false, count: w * h)
        for start in 0..<(w * h) where mask[start] == 0 && !seen[start] {
            var comp = [start]
            seen[start] = true
            var head = 0
            var touchesBorder = false
            while head < comp.count {
                let p = comp[head]; head += 1
                let px = p % w, py = p / w
                if px == 0 || py == 0 || px == w - 1 || py == h - 1 { touchesBorder = true }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = px + dx, ny = py + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let q = ny * w + nx
                    if mask[q] == 0 && !seen[q] { seen[q] = true; comp.append(q) }
                }
            }
            if !touchesBorder && comp.count <= maxArea { for p in comp { mask[p] = 255 } }
        }
    }
}
