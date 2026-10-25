import Foundation

/// A drag that runs into a limit stays at the limit, and moving back responds at once. Without this, a finger that went
/// past the end built up a hidden overshoot: nothing moved on the way back until the finger had returned to where the
/// limit was hit (owner, 25 Oct: "the slider is confused about what is 0"). Foundation only: the logic tests cover it.
enum EndStop {
    /// The value for a drag of `delta` (the whole drag so far) from `base`, kept in `range`. `base` takes up any overshoot,
    /// so the next call measures from the limit.
    static func value(base: inout Double, delta: Double, in range: ClosedRange<Double>) -> Double {
        let raw = base + delta
        let v = min(max(raw, range.lowerBound), range.upperBound)
        base += v - raw
        return v
    }
}
