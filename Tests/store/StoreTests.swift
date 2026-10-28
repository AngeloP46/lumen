// App Store build only: buys each Pro product against Tests/store/LumenRAW.storekit (StoreKit testing, no Apple
// account) and checks LumenStore unlocks Pro, shows the trial, and locks again when a subscription ends.
import XCTest
import StoreKit
import StoreKitTest
@testable import Lumen

@MainActor
final class StoreTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: StoreTests.self).url(forResource: "LumenRAW", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.resetToDefaultState()
        session.clearTransactions()
        try await waitForTestCatalog()
        await LumenStore.shared.refreshStatus()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        await LumenStore.shared.refreshStatus()
    }

    /// The hosted app can ask StoreKit for products before this test installs its local session. On a cold
    /// simulator that request can return no products while the test service is still activating. Establish
    /// fixture readiness first; loadedStore() below still exercises the app's actual product loader and prices.
    private func waitForTestCatalog() async throws {
        let deadline = Date().addingTimeInterval(30)
        var lastResult = "no response"
        repeat {
            do {
                let products = try await Product.products(for: LumenStore.proIDs)
                let ids = Set(products.map(\.id))
                if LumenStore.proIDs.isSubset(of: ids) { return }
                lastResult = "received product IDs: \(ids.sorted())"
            } catch {
                lastResult = "\(error)"
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        throw NSError(domain: "LumenStoreTests.StoreKitFixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The local StoreKit test catalog did not become ready within 30 seconds (\(lastResult))."])
    }

    private func loadedStore() async throws -> LumenStore {
        let store = LumenStore.shared
        store.loadProducts()
        for _ in 0..<40 where store.monthly == nil || store.annual == nil || store.lifetime == nil {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertNotNil(store.monthly, "monthly product should load")
        XCTAssertNotNil(store.annual, "annual product should load")
        XCTAssertNotNil(store.lifetime, "lifetime product should load")
        return store
    }

    /// Buys with the test session (the app's purchase() waits for a confirmation sheet a unit test can't tap), then
    /// waits for LumenStore to see it. On failure, says what StoreKit reports.
    private func buy(_ id: String, in store: LumenStore) async throws {
        _ = try await session.buyProduct(identifier: id)
        for _ in 0..<20 where !store.isPro {
            await store.refreshStatus()
            if store.isPro { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if !store.isPro {
            var seen: [String] = []
            for await r in Transaction.currentEntitlements {
                if case .verified(let t) = r {
                    seen.append("entitled \(t.productID) exp \(String(describing: t.expirationDate)) offer \(String(describing: t.offer?.paymentMode)) upgraded \(t.isUpgraded)")
                } else { seen.append("unverified entitlement") }
            }
            for await r in Transaction.all {
                if case .verified(let t) = r { seen.append("all \(t.productID) exp \(String(describing: t.expirationDate)) revoked \(String(describing: t.revocationDate))") }
            }
            XCTFail("\(id) bought but not Pro. StoreKit reports: \(seen.isEmpty ? "nothing" : seen.joined(separator: "; "))")
        }
    }

    func testProductsAndPrices() async throws {
        let store = try await loadedStore()
        XCTAssertEqual(store.monthly?.price, Decimal(string: "1.49"))
        XCTAssertEqual(store.annual?.price, Decimal(string: "9.99"))
        XCTAssertEqual(store.lifetime?.price, Decimal(string: "29.99"))
        XCTAssertEqual(store.lifetime?.type, .nonConsumable)
        XCTAssertEqual(store.monthly?.subscription?.introductoryOffer?.paymentMode, .freeTrial)
        for _ in 0..<20 where !store.monthlyTrialEligible {
            await store.refreshStatus()
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(store.monthlyTrialEligible, "a new account should be offered the free trial")
        XCTAssertFalse(store.isPro, "nothing bought yet")
    }

    func testLifetimeUnlocksProForGood() async throws {
        let store = try await loadedStore()
        try await buy(LumenStore.lifetimeID, in: store)
        XCTAssertEqual(store.status, .pro)
        XCTAssertTrue(store.isPro)
    }

    func testAnnualUnlocksPro() async throws {
        let store = try await loadedStore()
        try await buy(LumenStore.annualID, in: store)
        XCTAssertEqual(store.status, .pro)
    }

    func testMonthlyTrialThenEnds() async throws {
        let store = try await loadedStore()
        try await buy(LumenStore.monthlyID, in: store)
        XCTAssertEqual(store.status, .trialing, "the first month starts with the free trial")
        XCTAssertTrue(store.isPro)
        try session.expireSubscription(productIdentifier: LumenStore.monthlyID)
        for _ in 0..<20 where store.isPro {
            try await Task.sleep(nanoseconds: 250_000_000)
            await store.refreshStatus()
        }
        if store.isPro {
            var seen: [String] = []
            for await r in Transaction.currentEntitlements {
                if case .verified(let t) = r { seen.append("\(t.productID) exp \(String(describing: t.expirationDate)) now \(Date())") }
            }
            XCTFail("an ended subscription should lock Pro again; still entitled: \(seen.joined(separator: "; "))")
        }
    }
}
