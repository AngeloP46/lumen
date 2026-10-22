// DRAFT — sandbox, review required: exercise purchase/restore, offer eligibility and billing
// grace with StoreKit testing. Flag-off builds retain the always-Pro SideStore stub.
import Foundation
import Combine
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
    @Published private(set) var lifetime: Product?
    @Published private(set) var monthlyTrialEligible = false
    @Published var isBusy = false
    @Published var errorMessage: String?

    /// Product IDs — must match App Store Connect EXACTLY. Final name Lumen RAW (Angelo, 22 Oct): app
    /// com.lumenraw.app; £1.49 a month (7-day free trial), £9.99 a year, £29.99 once (lifetime, non-consumable).
    /// Tests/store/LumenRAW.storekit mirrors these for the CI purchase test.
    static let monthlyID = "com.lumenraw.pro.monthly"
    static let annualID = "com.lumenraw.pro.annual"
    static let lifetimeID = "com.lumenraw.pro.lifetime"
    static let proIDs: Set<String> = [monthlyID, annualID, lifetimeID]

    var isPro: Bool { status != .free }

    private var updatesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

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
                let all = try await Product.products(for: Self.proIDs)
                for p in all where p.id == Self.monthlyID { monthly = p }
                for p in all where p.id == Self.annualID { annual = p }
                for p in all where p.id == Self.lifetimeID { lifetime = p }
                await refreshTrialEligibility()
            } catch {
                // No products yet (unconfigured account, no network, sandbox build) — stay free, no crash.
                errorMessage = "Prices couldn't be loaded. Check your connection and try again."
            }
        }
    }

    func purchase(_ product: Product) async {
        guard !isBusy else { return }
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
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            await refreshStatus()
            if !isPro { errorMessage = "No Pro purchase or subscription was found for this Apple Account." }
        } catch {
            errorMessage = "Purchases couldn't be restored. Please try again."
        }
    }

    private func apply(_ t: Transaction) async {
        await refreshStatus()
        await t.finish()
    }

    /// Lifetime is a non-consumable: once bought it stays in currentEntitlements (no expiry), so it counts as paid Pro.
    /// StoreKit includes billing-grace-period subscriptions in currentEntitlements.
    /// Do not reject those because the original transaction's expiration is in the past.
    func refreshStatus() async {
        var hasAccess = false
        var hasPaidAccess = false
        var nextExpiry: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result,
                  Self.proIDs.contains(t.productID),
                  t.revocationDate == nil, !t.isUpgraded else { continue }
            hasAccess = true
            if t.offer?.paymentMode != .freeTrial { hasPaidAccess = true }
            if let exp = t.expirationDate, exp > Date() {
                nextExpiry = min(nextExpiry ?? exp, exp)
            }
        }
        status = !hasAccess ? .free : (hasPaidAccess ? .pro : .trialing)
        expiryTask?.cancel()
        if let nextExpiry {
            let delay = max(1, nextExpiry.timeIntervalSinceNow + 1)
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                await self?.refreshStatus()
            }
        }
        await refreshTrialEligibility()
    }

    private func refreshTrialEligibility() async {
        guard let subscription = monthly?.subscription,
              subscription.introductoryOffer?.paymentMode == .freeTrial else {
            monthlyTrialEligible = false
            return
        }
        monthlyTrialEligible = await subscription.isEligibleForIntroOffer
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
