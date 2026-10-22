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
        await LumenStore.shared.refreshStatus()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        await LumenStore.shared.refreshStatus()
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

    /// Buys through the app's own purchase code (what the paywall does), then waits for StoreKit to report it.
    private func buy(_ product: Product?, in store: LumenStore) async throws {
        let product = try XCTUnwrap(product)
        await store.purchase(product)
        XCTAssertNil(store.errorMessage, "purchase of \(product.id) said: \(store.errorMessage ?? "")")
        for _ in 0..<20 where !store.isPro {
            try await Task.sleep(nanoseconds: 250_000_000)
            await store.refreshStatus()
        }
    }

    func testProductsAndPrices() async throws {
        let store = try await loadedStore()
        XCTAssertEqual(store.monthly?.price, Decimal(string: "1.49"))
        XCTAssertEqual(store.annual?.price, Decimal(string: "9.99"))
        XCTAssertEqual(store.lifetime?.price, Decimal(string: "29.99"))
        XCTAssertEqual(store.lifetime?.type, .nonConsumable)
        XCTAssertEqual(store.monthly?.subscription?.introductoryOffer?.paymentMode, .freeTrial)
        XCTAssertTrue(store.monthlyTrialEligible, "a new account should be offered the free trial")
        XCTAssertFalse(store.isPro, "nothing bought yet")
    }

    func testLifetimeUnlocksProForGood() async throws {
        let store = try await loadedStore()
        try await buy(store.lifetime, in: store)
        XCTAssertEqual(store.status, .pro)
        XCTAssertTrue(store.isPro)
    }

    func testAnnualUnlocksPro() async throws {
        let store = try await loadedStore()
        try await buy(store.annual, in: store)
        XCTAssertEqual(store.status, .pro)
    }

    func testMonthlyTrialThenEnds() async throws {
        let store = try await loadedStore()
        try await buy(store.monthly, in: store)
        XCTAssertEqual(store.status, .trialing, "the first month starts with the free trial")
        XCTAssertTrue(store.isPro)
        try session.expireSubscription(productIdentifier: LumenStore.monthlyID)
        await store.refreshStatus()
        XCTAssertFalse(store.isPro, "an ended subscription locks Pro again")
    }
}
