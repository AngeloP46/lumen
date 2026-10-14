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
    @State private var showPrivacy = false

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
                        row(store.annual, primary: true)
                        row(store.monthly)
                    }

                    Text("Subscriptions renew automatically unless cancelled. Manage or cancel in your Apple Account subscription settings.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    HStack {
                        Button("Privacy Policy") { showPrivacy = true }
                        Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.footnote)
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
                    Button("Restore") { Task { await store.restore() } }.disabled(store.isBusy)
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showPrivacy) { AppPrivacyView() }
        .onChange(of: store.isPro) { _, isPro in if isPro { dismiss() } }
    }

    @ViewBuilder
    private func row(_ product: Product?, primary: Bool = false) -> some View {
        if let product {
            Button {
                Task { await store.purchase(product) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.displayName).font(.body.weight(.semibold))
                        Text(note(for: product)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(product.displayPrice).font(.body.weight(.semibold))
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

    private func note(for product: Product) -> String {
        guard let subscription = product.subscription else { return "" }
        let billing = periodText(subscription.subscriptionPeriod)
        if product.id == LumenStore.monthlyID, store.monthlyTrialEligible,
           let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial {
            return "\(periodText(offer.period, count: offer.numberOfPeriods)) free, then \(product.displayPrice) every \(billing). Renews automatically."
        }
        return "\(product.displayPrice) every \(billing). Renews automatically."
    }

    private func periodText(_ period: Product.SubscriptionPeriod, count: Int = 1) -> String {
        let value = period.value * count
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: return "subscription period"
        }
        return "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}
#endif
