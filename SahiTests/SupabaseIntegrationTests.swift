import XCTest
@testable import Sahi

/// End-to-end tests against a real Supabase project. They are skipped unless
/// these environment variables are set in the test scheme (Edit Scheme → Test →
/// Arguments → Environment Variables):
///
///   SAHI_TEST_SUPABASE_URL, SAHI_TEST_SUPABASE_ANON_KEY,
///   SAHI_TEST_A_EMAIL, SAHI_TEST_A_PASSWORD,
///   SAHI_TEST_B_EMAIL, SAHI_TEST_B_PASSWORD
///
/// Both accounts must be active members. Use a test project, not production:
/// the tests create a product named "בדיקת אינטגרציה".
final class SupabaseIntegrationTests: XCTestCase {
    private struct Environment {
        let config: AppConfig
        let emailA: String
        let passwordA: String
        let emailB: String
        let passwordB: String
    }

    private func environment() throws -> Environment {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SAHI_TEST_SUPABASE_URL"], let key = env["SAHI_TEST_SUPABASE_ANON_KEY"],
              let config = AppConfig.make(urlString: url, key: key),
              let emailA = env["SAHI_TEST_A_EMAIL"], let passwordA = env["SAHI_TEST_A_PASSWORD"],
              let emailB = env["SAHI_TEST_B_EMAIL"], let passwordB = env["SAHI_TEST_B_PASSWORD"]
        else {
            throw XCTSkip("Supabase integration tests need SAHI_TEST_* environment variables (see file header).")
        }
        return Environment(config: config, emailA: emailA, passwordA: passwordA, emailB: emailB, passwordB: passwordB)
    }

    /// Two independent sessions, like two volunteers' phones.
    private func twoSessions() async throws -> (SupabaseBackend, SupabaseBackend) {
        let env = try environment()
        let a = SupabaseBackend(config: env.config, authStorageKey: "sahi-test-a-\(UUID().uuidString)")
        let b = SupabaseBackend(config: env.config, authStorageKey: "sahi-test-b-\(UUID().uuidString)")
        try await a.signIn(email: env.emailA, password: env.passwordA)
        try await b.signIn(email: env.emailB, password: env.passwordB)
        return (a, b)
    }

    private let productName = "בדיקת אינטגרציה"

    func testAggregationAndRealtimeBetweenTwoSessions() async throws {
        let (a, b) = try await twoSessions()
        defer {
            Task {
                try? await a.signOut()
                try? await b.signOut()
            }
        }

        // A listens for changes.
        let received = expectation(description: "A receives B's change")
        received.assertForOverFulfill = false
        let listener = Task {
            for await event in a.realtimeEvents() {
                if case .tableChanged("inventory") = event {
                    received.fulfill()
                }
            }
        }
        defer { listener.cancel() }
        try await Task.sleep(for: .seconds(2)) // allow the subscription to join

        // Both volunteers add the same product: one row, summed quantity.
        let first = try await a.addStock(AddStockRequest(name: productName, unitCode: "unit", quantity: 10, categoryId: nil, notes: nil))
        let second = try await b.addStock(AddStockRequest(name: "  \(productName) ", unitCode: "unit", quantity: 5, categoryId: nil, notes: nil))
        XCTAssertEqual(first.productId, second.productId)
        XCTAssertEqual(second.newQuantity, (first.newQuantity ?? 0) + 5)

        await fulfillment(of: [received], timeout: 15)

        // Different unit stays separate.
        let kg = try await a.addStock(AddStockRequest(name: productName, unitCode: "kg", quantity: 1, categoryId: nil, notes: nil))
        XCTAssertNotEqual(kg.productId, first.productId)

        // Clean up stock created by this test.
        _ = try await a.adjustStock(AdjustStockRequest(productId: first.productId, delta: -15))
        _ = try await a.adjustStock(AdjustStockRequest(productId: kg.productId, delta: -1))
    }

    func testSimultaneousUpdatesAreNotLost() async throws {
        let (a, b) = try await twoSessions()
        let seed = try await a.addStock(AddStockRequest(name: productName, unitCode: "unit", quantity: 1, categoryId: nil, notes: nil))
        let start = try XCTUnwrap(seed.newQuantity)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let backend = index.isMultiple(of: 2) ? a : b
                group.addTask {
                    _ = try await backend.adjustStock(AdjustStockRequest(productId: seed.productId, delta: 1))
                }
            }
            try await group.waitForAll()
        }

        let items = try await b.fetchInventory(includeArchived: false)
        XCTAssertEqual(items.first { $0.id == seed.productId }?.quantity, start + 20)

        _ = try await a.adjustStock(AdjustStockRequest(productId: seed.productId, delta: -(start + 20)))
        try? await a.signOut()
        try? await b.signOut()
    }

    func testIdempotentRetryAndValidation() async throws {
        let (a, b) = try await twoSessions()
        let request = AddStockRequest(name: productName, unitCode: "unit", quantity: 2, categoryId: nil, notes: nil)
        let first = try await a.addStock(request)
        let retry = try await a.addStock(request)
        XCTAssertTrue(retry.replayed)
        XCTAssertEqual(retry.newQuantity, first.newQuantity)

        do {
            _ = try await b.adjustStock(AdjustStockRequest(productId: first.productId, delta: -1_000_000))
            XCTFail("expected insufficient stock")
        } catch {
            XCTAssertEqual(error as? AppError, .insufficientStock)
        }

        _ = try await a.adjustStock(AdjustStockRequest(productId: first.productId, delta: -2))
        try? await a.signOut()
        try? await b.signOut()
    }
}
