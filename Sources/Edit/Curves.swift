import Foundation

struct CurvePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

/// Master + per-channel tone curves. Each curve is a list of control points in 0...1.
struct ToneCurves: Codable, Equatable, Hashable {
    static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    var master: [CurvePoint] = ToneCurves.identity
    var red: [CurvePoint] = ToneCurves.identity
    var green: [CurvePoint] = ToneCurves.identity
    var blue: [CurvePoint] = ToneCurves.identity

    var isNeutral: Bool {
        master == Self.identity && red == Self.identity && green == Self.identity && blue == Self.identity
    }

    func points(_ channel: Int) -> [CurvePoint] {
        switch channel {
        case 1: red
        case 2: green
        case 3: blue
        default: master
        }
    }

    mutating func set(_ channel: Int, _ pts: [CurvePoint]) {
        switch channel {
        case 1: red = pts
        case 2: green = pts
        case 3: blue = pts
        default: master = pts
        }
    }

    /// Monotone cubic (Fritsch–Carlson) interpolation sampled into a lookup table.
    static func lut(for raw: [CurvePoint], size: Int = 256) -> [Float] {
        let p = raw.sorted { $0.x < $1.x }
        let n = p.count
        guard n >= 2 else { return (0..<size).map { Float($0) / Float(size - 1) } }

        var dx = [Double](), slope = [Double]()
        for i in 0..<(n - 1) {
            let d = max(p[i + 1].x - p[i].x, 1e-6)
            dx.append(d)
            slope.append((p[i + 1].y - p[i].y) / d)
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = slope[0]
        m[n - 1] = slope[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                m[i] = slope[i - 1] * slope[i] <= 0 ? 0 : (slope[i - 1] + slope[i]) / 2
            }
        }
        for i in 0..<(n - 1) {
            if slope[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
            } else {
                let a = m[i] / slope[i]
                let b = m[i + 1] / slope[i]
                let h = (a * a + b * b).squareRoot()
                if h > 3 {
                    let t = 3 / h
                    m[i] = t * a * slope[i]
                    m[i + 1] = t * b * slope[i]
                }
            }
        }

        var out = [Float](repeating: 0, count: size)
        var seg = 0
        for k in 0..<size {
            let x = Double(k) / Double(size - 1)
            while seg < n - 2 && x > p[seg + 1].x { seg += 1 }
            let t = min(max((x - p[seg].x) / dx[seg], 0), 1)
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let y = h00 * p[seg].y + h10 * dx[seg] * m[seg] + h01 * p[seg + 1].y + h11 * dx[seg] * m[seg + 1]
            out[k] = Float(min(max(y, 0), 1))
        }
        return out
    }
}
