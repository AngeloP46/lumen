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

    /// A SOLID dark badge, not a faint material: a 30%-opacity white capsule was invisible
    /// on bright skies (Angelo, 14 Oct: "no difference between with and without"). A solid
    /// backing reads on any photo — bright sky or dark scene — because the dark pill is what
    /// carries the mark, not the photo behind it.
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sun.max.fill")   // placeholder glyph — final mark = the app logo
                .font(.system(size: 30, weight: .bold))
            Text("Lumaforge")   // placeholder name (plan §11.1)
                .font(.system(size: 26, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.72), in: Capsule())
        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
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
