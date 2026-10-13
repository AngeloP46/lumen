// DRAFT — sandbox, review required: SwiftUI layout not compiled. Check: Product display
// formatting, restore availability, and that closing the sheet leaves the app fully usable
// (Apple requirement — the free tier must stay functional).
import SwiftUI
#if APP_STORE
import StoreKit

/// Shown only at the export gate when a Pro feature is active and the user is not Pro.
/// Content per plan §4.4: what Pro unlocks, both prices from the loaded Products (never
/// hardcoded), trial line, Restore (Apple requirement), privacy line, a free close path.
struct PaywallView: View {
    @ObservedObject var store: LumenStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Lumaforge Pro")
                        .font(.title.bold())
                    Text("This photo uses Pro features (curves, detail, masks or heal). Upgrade to export it clean and full-resolution.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        row(store.annual, price: store.annual?.displayPrice,
                            note: "7 days free, then renews", primary: true)
                        row(store.monthly, price: store.monthly?.displayPrice,
                            note: "7 days free, then renews")
                    }

                    if store.status == .free {
                        Text("Start with 7 days free. Cancel any time in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if store.isBusy {
                        ProgressView()
                    }
                    if let message = store.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    Text("Your photos are edited on your device. Lumaforge never sees or stores them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .navigationTitle("Unlock Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep editing free") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Restore") { Task { await store.restore() } }
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func row(_ product: Product?, price: String?, note: String, primary: Bool = false) -> some View {
        if let product, let price {
            Button {
                Task { await store.purchase(product) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.displayName).font(.body.weight(.semibold))
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(price).font(.body.weight(.semibold))
                }
                .padding(16)
                .background(primary ? Color.orange : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(store.isBusy)
        } else {
            // Products not loaded yet (no network / unconfigured account): one tappable row
            // that retries, so the paywall is never an empty dead end.
            Button { store.loadProducts() } label: {
                Label("Loading…", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
#endif
