// DRAFT — sandbox, review required: not compiled in Xcode (no Xcode on the dev PC).
// Verify StoreKit 2 API usage, the trial heuristic in refreshStatus(), and that the stub
// path compiles for the SideStore build (flag off).
import Foundation
#if APP_STORE
import StoreKit

/// App Store build: real StoreKit 2. No SKPaymentQueue, no backend — all on Apple's side.
/// Plan: docs/APPSTORE-PLAN.md §4.2/§4.4.
@MainActor
final class LumenStore: ObservableObject {
    static let shared = LumenStore()

    enum ProStatus: Equatable {
        case free
        case trialing   // the 7-day free trial is running
        case pro
    }

    @Published private(set) var status: ProStatus = .free
    @Published private(set) var monthly: Product?
    @Published private(set) var annual: Product?
    @Published var isBusy = false
    @Published var errorMessage: String?

    /// Product IDs — must match App Store Connect EXACTLY (created at Gate 4).
    /// "Lumaforge" is the placeholder name; the IDs should be re-decided with the final name.
    static let monthlyID = "lumaforge.pro.monthly"
    static let annualID = "lumaforge.pro.annual"

    var isPro: Bool { status != .free }

    private var updatesTask: Task<Void, Never>?

    private init() {
        loadProducts()
        Task { await refreshStatus() }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let t) = result { await self.apply(t) }
            }
        }
    }

    func loadProducts() {
        Task {
            do {
                let all = try await Product.products(for: [Self.monthlyID, Self.annualID])
                for p in all where p.id == Self.monthlyID { monthly = p }
                for p in all where p.id == Self.annualID { annual = p }
            } catch {
                // No products yet (unconfigured account, no network, sandbox build) — stay free, no crash.
                print("LumenStore: product load failed: \(error)")
            }
        }
    }

    func purchase(_ product: Product) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let t) = verification {
                    await apply(t)
                } else {
                    errorMessage = "The purchase could not be verified. Please try again."
                }
            case .userCancelled:
                break
            case .pending:
                errorMessage = "The purchase is pending (for example, it needs parental approval)."
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }

    /// Apple requirement: restore must work for subscriptions (AppStore.sync + entitlements).
    func restore() async {
        isBusy = true
        defer { isBusy = false }
        try? await AppStore.sync()
        await refreshStatus()
    }

    private func apply(_ t: Transaction) async {
        do { try await t.finish() } catch { print("LumenStore: finish failed: \(error)") }
        await refreshStatus()
    }

    /// Reads the current entitlements.
    /// TRIAL HEURISTIC (review required): a monthly purchase expiring within ~8 days is treated
    /// as the 7-day trial. Cleaner: check `t.purchaseInformation`/offer info — Claude to confirm.
    private func refreshStatus() async {
        var best: (expiry: Date, isTrial: Bool)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result,
                  t.productID == Self.monthlyID || t.productID == Self.annualID,
                  let exp = t.expirationDate,   // Date? in StoreKit 2
                  exp > Date() else { continue }
            let isTrial = t.productID == Self.monthlyID && exp.timeIntervalSinceNow < 8 * 86400
            if best == nil || exp > best!.expiry { best = (exp, isTrial) }
        }
        status = best == nil ? .free : (best!.isTrial ? .trialing : .pro)
    }
}

#else

// SideStore / non-App-Store build: no StoreKit, no paywall, no watermark — always Pro.
// (Plan §2.1: the SideStore app behaves exactly as it does today.)
@MainActor
final class LumenStore: ObservableObject {
    static let shared = LumenStore()

    enum ProStatus: Equatable {
        case free
        case trialing
        case pro
    }

    @Published private(set) var status: ProStatus = .pro

    var isPro: Bool { true }

    private init() {}
}

#endif
