import Foundation

/// One-tap "Auto": picks exposure, tone and a touch of contrast from the photo's brightness distribution.
extension EditSession {
    func autoSettings(source: ImageSource, current: EditSettings) -> EditSettings {
        var s = current
        let g = source.stats
        var lum: [Float] = []
        lum.reserveCapacity(g.width * g.height)
        for i in 0..<(g.width * g.height) {
            let y = 0.22897 * g.data[i * 4] + 0.69174 * g.data[i * 4 + 1] + 0.07929 * g.data[i * 4 + 2]
            lum.append(max(y, 1e-5))
        }
        lum.sort()
        func pct(_ p: Float) -> Float { lum[min(lum.count - 1, Int(Float(lum.count) * p))] }
        let median = pct(0.5), low = pct(0.03), high = pct(0.985)

        let ev = max(-2, min(2, log2(0.16 / median) * 0.75))
        s.exposure = (Double(ev) * 20).rounded() / 20
        let high2 = high * exp2(Float(s.exposure))
        let low2 = low * exp2(Float(s.exposure))
        s.highlights = high2 > 0.9 ? -Double(min(80, (high2 - 0.9) * 400 + 20)) : -10
        s.shadows = low2 < 0.02 ? Double(min(70, (0.02 - low2) * 3000 + 20)) : 10
        s.whites = high2 < 0.7 ? Double(min(50, (0.7 - high2) * 100)) : 0
        s.blacks = low2 > 0.01 ? -Double(min(40, low2 * 600)) : 0
        s.contrast = 12
        s.vibrance = 15
        s.clarity = max(s.clarity, 8)
        return s
    }
}
