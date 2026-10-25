import Foundation

/// A drag that runs into a limit stays at the limit, and moving back responds at once. Without this, a finger that went
/// past the end built up a hidden overshoot: nothing moved on the way back until the finger had returned to where the
/// limit was hit (owner, 25 Oct: "the slider is confused about what is 0"). Foundation only: the logic tests cover it.
/// A slider drag with a detent at neutral (owner, 25 Oct: "the smallest value I can select is 3, any less and it reverts to
/// 0"). Passing through neutral, the value rests there for `hold` points of finger travel, then carries on, so neutral is
/// easy to land on and every value next to it can still be chosen; it never leaves the range and keeps no overshoot.
/// Before, anything within 1.2 % of the span snapped to neutral. Foundation only: the logic tests cover it.
struct DetentDrag {
    var value: Double                    // not rounded yet
    let neutral: Double
    let range: ClosedRange<Double>
    var hold: Double = 12
    /// Points travelled inside the detent; nil when not in it.
    private(set) var held: Double?

    init(value: Double, neutral: Double, range: ClosedRange<Double>, hold: Double = 12) {
        self.value = value; self.neutral = neutral; self.range = range; self.hold = hold
    }

    mutating func move(points: Double, perPoint: Double) {
        if var h = held {
            h += points
            if abs(h) < hold { held = h; return }
            held = nil
            value = clamp(neutral + (abs(h) - hold) * (h > 0 ? 1 : -1) * perPoint)
            return
        }
        let before = value - neutral
        value = clamp(value + points * perPoint)
        let after = value - neutral
        // arriving at or passing through neutral rests there; leaving it does not
        if before != 0 && (after == 0 || (before > 0) != (after > 0)) {
            value = neutral
            held = 0
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
}

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
