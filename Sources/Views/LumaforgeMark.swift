// DRAFT — sandbox, review required: placement/opacity not eyeballed on a real screen.
// Angelo's decision (plan §5.1/§11): clearly visible, large, on Pro-edited previews only,
// App Store build only. Two placement variants so he can pick on his phone before Gate 2.
import SwiftUI
#if APP_STORE

/// Watermark overlay for the editor preview (free users + active Pro features only).
/// Pure view-layer — does not touch the Core Image or export pipelines.
enum LumaforgeMarkPlacement {
    /// Bottom of the photo (default): the top corners are taken by the toolbar icons.
    /// The top-corner variant is kept so Angelo can compare.
    static var choice: Self = .bottom
    case corner, bottom
}

struct LumaforgeMark: View {
    let placement: LumaforgeMarkPlacement = LumaforgeMarkPlacement.choice
    /// Big and clearly visible (plan §5.1). ~40 % of screen width; shadow so it reads
    /// on bright skies and dark scenes alike.
    private var opacity: Double = 0.3

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")   // placeholder glyph — final mark = the app logo
                .font(.system(size: 28, weight: .bold))
            Text("Lumaforge")   // placeholder name (plan §11.1)
                .font(.system(size: 24, weight: .bold))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
