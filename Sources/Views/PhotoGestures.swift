import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Two-finger pinch and pan on the photo, in every tool and over the crop/mask overlays.
///
/// It only *watches* the fingers: it never recognises, so it can never cancel, delay or block another gesture (taps,
/// hold-to-compare, swipes, mask handles, the brush). SwiftUI's own pinch only reports the point where the pinch
/// started, so the photo could not follow the fingers; this reports the point between the two fingers and the distance
/// between them on every move. A finger landing or lifting ends the pinch and starts a new one from where things are,
/// so nothing ever jumps.
final class TwoFingerWatcher: UIGestureRecognizer {
    enum Phase { case began, changed, ended }
    /// Phase, point between the first two fingers (window coordinates), distance between them.
    var onPinch: ((Phase, CGPoint, CGFloat) -> Void)?

    private var down: [UITouch] = []
    private var tracking = false

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches where !down.contains(t) { down.append(t) }
        restart()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if tracking, let m = measure() { onPinch?(.changed, m.0, m.1) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    override func reset() {
        super.reset()
        if tracking { onPinch?(.ended, .zero, 0) }
        down = []
        tracking = false
    }

    private func lift(_ touches: Set<UITouch>) {
        down.removeAll { touches.contains($0) }
        restart()
        if down.isEmpty { state = .failed }   // done watching; nothing was claimed
    }

    private func restart() {
        if tracking { onPinch?(.ended, .zero, 0); tracking = false }
        if let m = measure() { tracking = true; onPinch?(.began, m.0, m.1) }
    }

    private func measure() -> (CGPoint, CGFloat)? {
        guard down.count >= 2 else { return nil }
        let a = down[0].location(in: nil), b = down[1].location(in: nil)
        return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), max(hypot(a.x - b.x, a.y - b.y), 1))
    }
}

/// Attaches a `TwoFingerWatcher` to a SwiftUI view; `onPinch` gets the centroid in window coordinates.
struct TwoFingerGesture: UIGestureRecognizerRepresentable {
    var onPinch: (TwoFingerWatcher.Phase, CGPoint, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> TwoFingerWatcher {
        let g = TwoFingerWatcher(target: nil, action: nil)
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.onPinch = onPinch
        return g
    }

    func updateUIGestureRecognizer(_ recognizer: TwoFingerWatcher, context: Context) {
        recognizer.onPinch = onPinch
    }

    func handleUIGestureRecognizerAction(_ recognizer: TwoFingerWatcher, context: Context) {}
}
