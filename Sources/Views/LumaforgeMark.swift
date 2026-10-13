// DRAFT — sandbox, review required: placement/opacity not eyeballed on a real screen.
// Angelo's decision (plan §5.1/§11): clearly visible, large, on Pro-edited previews only,
// App Store build only. Two placement variants so he can pick on his phone before Gate 2.
import SwiftUI
#if APP_STORE

/// Watermark overlay for the editor preview (free users + active Pro features only).
/// Pure view-layer — does not touch the Core Image or export pipelines.
enum LumaforgeMarkPlacement {
    static var choice: Self = .corner   // Angelo to pick after seeing both on device
    case corner, bottom
}

struct LumaforgeMark: View {
    let placement: LumaforgeMarkPlacement = LumaforgeMarkPlacement.choice
    /// ~25–35 % of screen width, 15–25 % opacity per plan §5.1.
    private var size: CGFloat = 110
    private var opacity: Double = 0.22

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.max.fill")   // placeholder glyph — final mark = the app logo
                .font(.system(size: 20, weight: .bold))
            Text("Lumaforge")   // placeholder name (plan §11.1)
                .font(.system(size: 17, weight: .bold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(opacity)
        .allowsHitTesting(false)   // never blocks gestures
        .accessibilityIdentifier("lumaforge-mark")
    }
}

/// How EditorView wires it (draft hook — see SANDBOX-LOG.md):
///
///   CanvasView(model: vm.canvas, xform: xform, hdr: vm.settings.hdr)
///       .allowsHitTesting(false)
/// #if APP_STORE
///   if vm.settings.usesProFeatures && !LumenStore.shared.isPro {
///       LumaforgeMark().padding(12)
///   }
/// #endif
///
/// (The mark is positioned by the surrounding ZStack; .corner = topTrailing,
///  .bottom = bottom leading above the toolbar.)
#endif
