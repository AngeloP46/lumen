// DRAFT — sandbox, review required: tiled look not eyeballed on a real screen yet.
// Angelo's decision (plan §5.1/§11): clearly visible, on Pro-edited previews only, App Store
// build only. 14 Oct: the single solid badge "looked like a button" — replaced with the classic
// protection style used by other photo apps: the app name tiled diagonally across the whole
// photo at low opacity, so a screenshot of a free edit is clearly unusable as a final image.
import SwiftUI
#if APP_STORE

struct LumaforgeMark: View {
    var body: some View {
        Canvas { context, size in
            context.drawLayer { layer in
                // rotate the whole tiling so the rows run diagonally
                layer.translateBy(x: size.width / 2, y: size.height / 2)
                layer.rotate(by: .degrees(-24))
                let tile = layer.resolve(
                    Text("Lumaforge")   // placeholder name (plan §11.1)
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(.white)
                )
                // faint dark shadow so the white text reads on bright skies AND dark scenes
                layer.addFilter(.shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1))
                let stepX: CGFloat = 250
                let stepY: CGFloat = 130
                // cover the whole (rotated) area: a square wider than the diagonal is enough
                let half = max(size.width, size.height)
                var y: CGFloat = -half
                var row = 0
                while y < half {
                    // stagger every second row like a brick wall so the tiling looks even
                    let shift: CGFloat = row.isMultiple(of: 2) ? 0 : stepX / 2
                    var x = -half - shift
                    while x < half {
                        layer.draw(tile, at: CGPoint(x: x + stepX / 2, y: y), anchor: .center)
                        x += stepX
                    }
                    y += stepY
                    row += 1
                }
            }
        }
        .opacity(0.45)   // obvious on every photo (the point: a free edit is clearly not final), photo still shows through
        .allowsHitTesting(false)   // never blocks gestures
        .accessibilityIdentifier("lumaforge-mark")
    }
}
#endif
