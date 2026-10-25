import Foundation
import XCTest
@testable import Sahi

// MARK: - Fixtures

enum Fixtures {
    static let grainsId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let cannedId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let dairyId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    static let categories: [ProductCategory] = [
        ProductCategory(id: grainsId, slug: "grains", nameHe: "קטניות ודגנים", nameEn: nil, nameRu: nil, icon: "leaf", sortOrder: 20, isActive: true),
        ProductCategory(id: cannedId, slug: "canned", nameHe: "שימורים", nameEn: nil, nameRu: nil, icon: "shippingbox", sortOrder: 30, isActive: true),
        ProductCategory(id: dairyId, slug: "dairy", nameHe: "מוצרי חלב", nameEn: nil, nameRu: nil, icon: "waterbottle", sortOrder: 40, isActive: true),
    ]

    static let units = MeasurementUnit.defaults
    static var unitsByCode: [String: MeasurementUnit] {
        Dictionary(uniqueKeysWithValues: units.map { ($0.code, $0) })
    }

    static func item(
        _ name: String,
        quantity: Decimal,
        unit: String = "unit",
        category: UUID? = grainsId,
        updatedAt: Date = Date(),
        isActive: Bool = true,
        id: UUID = UUID(),
        stockVersion: Int = 1
    ) -> InventoryItem {
        InventoryItem(
            id: id, name: name, nameKey: ProductNameNormalizer.key(name), variant: "",
            categoryId: category, unitCode: unit, notes: nil, isActive: isActive,
            quantity: quantity, productVersion: 1, stockVersion: stockVersion,
            createdAt: updatedAt, updatedAt: updatedAt, updatedByName: "מתנדב/ת"
        )
    }

    /// The example inventory from the product brief (development data only).
    static var sampleInventory: [InventoryItem] {
        [
            item("אורז", quantity: 25),
            item("שמן", quantity: 18, unit: "bottle", category: nil),
            item("פסטה", quantity: 40),
            item("טונה", quantity: 32, unit: "box", category: cannedId),
            item("חלב", quantity: 12, unit: "liter", category: dairyId),
            item("סוכר", quantity: 15, unit: "kg", category: nil),
        ]
    }

    static func result(for productId: UUID, previous: Decimal, new: Decimal, kind: ActivityEntry.Kind = .increase) -> StockChangeResult {
        StockChangeResult(
            movementId: Int64.random(in: 1...1_000_000), productId: productId, kind: kind,
            quantityDelta: new - previous, previousQuantity: previous, newQuantity: new, replayed: false
        )
    }

    static func temporaryStore() -> LocalStore {
        LocalStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SahiTests-\(UUID().uuidString)", isDirectory: true))
    }
}

// MARK: - Repository

/// Scriptable in-memory repository. It does not re-implement the server's
/// rules (those are tested against Postgres in supabase/tests); it records
/// calls and returns what each test configures.
final class MockInventoryRepository: InventoryRepository, @unchecked Sendable {
    var items: [InventoryItem] = []
    var units: [MeasurementUnit] = Fixtures.units
    var categories: [ProductCategory] = Fixtures.categories
    var activity: [ActivityEntry] = []

    var fetchError: Error?
    var writeError: Error?

    private(set) var fetchInventoryCount = 0
    private(set) var addRequests: [AddStockRequest] = []
    private(set) var adjustRequests: [AdjustStockRequest] = []
    private(set) var setRequests: [SetStockRequest] = []
    private(set) var updateRequests: [UpdateProductRequest] = []
    private(set) var archived: [UUID] = []

    /// Simulated network latency for write calls.
    var writeDelay: Duration = .zero

    private var realtimeContinuation: AsyncStream<RealtimeEvent>.Continuation?

    func fetchUnits() async throws -> [MeasurementUnit] {
        if let fetchError { throw fetchError }
        return units
    }

    func fetchCategories() async throws -> [ProductCategory] {
        if let fetchError { throw fetchError }
        return categories
    }

    func fetchInventory(includeArchived: Bool) async throws -> [InventoryItem] {
        fetchInventoryCount += 1
        if let fetchError { throw fetchError }
        return includeArchived ? items : items.filter(\.isActive)
    }

    func fetchActivity(productId: UUID?, limit: Int) async throws -> [ActivityEntry] {
        if let fetchError { throw fetchError }
        return Array(activity.filter { productId == nil || $0.productId == productId }.prefix(limit))
    }

    func addStock(_ request: AddStockRequest) async throws -> StockChangeResult {
        addRequests.append(request)
        if writeDelay > .zero { try await Task.sleep(for: writeDelay) }
        if let writeError { throw writeError }
        let key = ProductNameNormalizer.key(request.name)
        if let index = items.firstIndex(where: { $0.nameKey == key && $0.unitCode == request.unitCode }) {
            let previous = items[index].quantity
            items[index].quantity += request.quantity
            return Fixtures.result(for: items[index].id, previous: previous, new: items[index].quantity)
        }
        let item = Fixtures.item(request.name, quantity: request.quantity, unit: request.unitCode, category: request.categoryId)
        items.append(item)
        return Fixtures.result(for: item.id, previous: 0, new: request.quantity, kind: .create)
    }

    func adjustStock(_ request: AdjustStockRequest) async throws -> StockChangeResult {
        adjustRequests.append(request)
        if writeDelay > .zero { try await Task.sleep(for: writeDelay) }
        if let writeError { throw writeError }
        guard let index = items.firstIndex(where: { $0.id == request.productId }) else { throw AppError.productNotFound }
        let previous = items[index].quantity
        guard previous + request.delta >= 0 else { throw AppError.insufficientStock }
        items[index].quantity += request.delta
        items[index].stockVersion += 1
        return Fixtures.result(for: request.productId, previous: previous, new: items[index].quantity)
    }

    func setStock(_ request: SetStockRequest) async throws -> StockChangeResult {
        setRequests.append(request)
        if let writeError { throw writeError }
        guard let index = items.firstIndex(where: { $0.id == request.productId }) else { throw AppError.productNotFound }
        guard items[index].stockVersion == request.expectedVersion else { throw AppError.versionConflict }
        let previous = items[index].quantity
        items[index].quantity = request.newQuantity
        items[index].stockVersion += 1
        return Fixtures.result(for: request.productId, previous: previous, new: request.newQuantity, kind: .set)
    }

    func updateProduct(_ request: UpdateProductRequest) async throws {
        updateRequests.append(request)
        if let writeError { throw writeError }
        guard let index = items.firstIndex(where: { $0.id == request.productId }) else { throw AppError.productNotFound }
        guard items[index].productVersion == request.expectedVersion else { throw AppError.versionConflict }
        items[index].name = request.name
        items[index].nameKey = ProductNameNormalizer.key(request.name)
        items[index].categoryId = request.categoryId
        items[index].productVersion += 1
    }

    func archiveProduct(id: UUID, reason: String?) async throws {
        if let writeError { throw writeError }
        archived.append(id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isActive = false
            items[index].quantity = 0
        }
    }

    func restoreProduct(id: UUID) async throws {
        if let writeError { throw writeError }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isActive = true
        }
    }

    func realtimeEvents() -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream()
        realtimeContinuation = continuation
        return stream
    }

    /// Simulates another volunteer's change arriving through realtime.
    func emit(_ event: RealtimeEvent) {
        realtimeContinuation?.yield(event)
    }
}

// MARK: - Connectivity

@MainActor
final class MockConnectivity: ConnectivityProviding {
    private var continuations: [AsyncStream<Bool>.Continuation] = []

    var isOnline: Bool {
        didSet {
            guard oldValue != isOnline else { return }
            continuations.forEach { $0.yield(isOnline) }
        }
    }

    init(isOnline: Bool = true) {
        self.isOnline = isOnline
    }

    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        continuations.append(continuation)
        return stream
    }
}

// MARK: - Auth & profiles

final class MockAuthService: AuthService, @unchecked Sendable {
    private var continuation: AsyncStream<AuthState>.Continuation?
    var signInError: Error?
    var signUpOutcome: SignUpOutcome = .signedIn
    private(set) var signedOut = false

    func authStates() -> AsyncStream<AuthState> {
        let (stream, continuation) = AsyncStream<AuthState>.makeStream()
        self.continuation = continuation
        return stream
    }

    var isSubscribed: Bool { continuation != nil }

    func emit(_ state: AuthState) {
        continuation?.yield(state)
    }

    func signIn(email: String, password: String) async throws {
        if let signInError { throw signInError }
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        signUpOutcome
    }

    func sendPasswordReset(email: String) async throws {}

    func signOut() async throws {
        signedOut = true
        continuation?.yield(.signedOut)
    }
}

final class MockProfileRepository: ProfileRepository, AdminRepository, @unchecked Sendable {
    var profile: UserProfile?
    var joinResult: AppError?
    var fetchError: Error?
    private(set) var joinCodes: [String] = []

    func fetchProfile(userId: UUID) async throws -> UserProfile? {
        if let fetchError { throw fetchError }
        return profile
    }

    func joinWithCode(_ code: String) async throws -> AppError? {
        joinCodes.append(code)
        if joinResult == nil {
            profile?.role = .volunteer
        }
        return joinResult
    }

    func updateDisplayName(_ name: String) async throws -> UserProfile {
        profile?.displayName = name
        guard let profile else { throw AppError.notMember }
        return profile
    }

    func listMembers() async throws -> [Member] { [] }
    func updateMember(id: UUID, role: MemberRole, isActive: Bool) async throws {}
    func setJoinCode(_ code: String) async throws {}
}

// MARK: - Async helpers

extension XCTestCase {
    /// Polls `condition` on the main actor until it holds or the timeout expires.
    @MainActor
    func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Condition not met within \(timeout)s", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
