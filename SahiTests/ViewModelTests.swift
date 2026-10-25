import XCTest
@testable import Sahi

@MainActor
final class AddProductViewModelTests: XCTestCase {
    private var repository: MockInventoryRepository!
    private var store: InventoryStore!

    override func setUp() async throws {
        repository = MockInventoryRepository()
        repository.items = Fixtures.sampleInventory
        store = InventoryStore(repository: repository, connectivity: MockConnectivity(), localStore: Fixtures.temporaryStore())
        await store.refresh()
    }

    func testInvalidInputShowsHebrewErrorsAndSendsNothing() async {
        let viewModel = AddProductViewModel(store: store)
        XCTAssertNil(viewModel.nameIssue, "no errors before the first save attempt")
        let outcome = await viewModel.submit()
        XCTAssertNil(outcome)
        XCTAssertEqual(viewModel.nameIssue, .nameEmpty)
        XCTAssertEqual(viewModel.quantityIssue, .quantityEmpty)
        XCTAssertEqual(viewModel.unitIssue, .unitMissing)
        XCTAssertTrue(repository.addRequests.isEmpty)
    }

    func testAddingNewProduct() async {
        let viewModel = AddProductViewModel(store: store)
        viewModel.name = "  קמח   מלא "
        viewModel.quantityText = "2,5"
        viewModel.selectUnit("kg")
        viewModel.categoryId = Fixtures.grainsId
        viewModel.notes = " תרומה "
        let outcome = await viewModel.submit()
        guard case .saved(let message) = outcome else { return XCTFail("expected saved") }
        XCTAssertTrue(message.contains("קמח מלא"))
        let request = repository.addRequests.first
        XCTAssertEqual(request?.name, "קמח מלא")
        XCTAssertEqual(request?.quantity, Decimal(string: "2.5"))
        XCTAssertEqual(request?.notes, "תרומה")
        XCTAssertEqual(request?.categoryId, Fixtures.grainsId)
    }

    func testDetectsExistingProductOnlyInSameUnit() {
        let viewModel = AddProductViewModel(store: store)
        viewModel.name = "אורז"
        viewModel.selectUnit("unit")
        XCTAssertEqual(viewModel.existingProduct?.quantity, 25)
        viewModel.quantityText = "10"
        XCTAssertEqual(viewModel.resultingQuantity, 35)

        viewModel.selectUnit("kg")
        XCTAssertNil(viewModel.existingProduct, "kilograms are never added to units")
        XCTAssertEqual(viewModel.sameNameOtherUnits.map(\.unitCode), ["unit"])
    }

    func testCountUnitsDropFractions() {
        let viewModel = AddProductViewModel(store: store)
        viewModel.quantityText = "2.7"
        viewModel.selectUnit("box")
        XCTAssertEqual(viewModel.quantityText, "2")
    }

    func testDoubleSubmitSendsOnce() async {
        repository.writeDelay = .milliseconds(200)
        let viewModel = AddProductViewModel(store: store)
        viewModel.name = "טונה"
        viewModel.quantityText = "5"
        viewModel.selectUnit("box")

        async let first = viewModel.submit()
        async let second = viewModel.submit()
        let outcomes = await [first, second]

        XCTAssertEqual(outcomes.compactMap { $0 }.count, 1)
        XCTAssertEqual(repository.addRequests.count, 1)
    }

    func testRetryUsesSameRequestId() async {
        let viewModel = AddProductViewModel(store: store)
        viewModel.name = "שעועית"
        viewModel.quantityText = "3"
        viewModel.selectUnit("box")
        repository.writeError = AppError.server("boom")
        _ = await viewModel.submit()
        XCTAssertNotNil(viewModel.serverError)
        repository.writeError = nil
        _ = await viewModel.submit()
        XCTAssertEqual(repository.addRequests.count, 2)
        XCTAssertEqual(repository.addRequests[0].requestId, repository.addRequests[1].requestId)
    }

    func testSuggestionFillsUnitAndCategory() {
        let viewModel = AddProductViewModel(store: store)
        viewModel.name = "טו"
        let suggestion = viewModel.suggestions.first
        XCTAssertEqual(suggestion?.name, "טונה")
        viewModel.selectSuggestion(suggestion!)
        XCTAssertEqual(viewModel.unitCode, "box")
        XCTAssertEqual(viewModel.categoryId, Fixtures.cannedId)
        XCTAssertNotNil(viewModel.existingProduct)
    }
}

@MainActor
final class AdjustStockViewModelTests: XCTestCase {
    private var repository: MockInventoryRepository!
    private var store: InventoryStore!
    private var rice: InventoryItem!

    override func setUp() async throws {
        repository = MockInventoryRepository()
        repository.items = Fixtures.sampleInventory
        store = InventoryStore(repository: repository, connectivity: MockConnectivity(), localStore: Fixtures.temporaryStore())
        await store.refresh()
        rice = store.items.first { $0.name == "אורז" }
    }

    func testCannotRemoveMoreThanAvailable() async {
        let viewModel = AdjustStockViewModel(store: store, productId: rice.id, mode: .decrease)
        viewModel.quantityText = "30"
        XCTAssertFalse(viewModel.validate())
        XCTAssertEqual(viewModel.quantityIssue, .insufficientStock(available: "25"))
        let outcome = await viewModel.submit()
        XCTAssertNil(outcome)
        XCTAssertTrue(repository.adjustRequests.isEmpty)
    }

    func testDecreaseSendsNegativeDeltaWithReason() async {
        let viewModel = AdjustStockViewModel(store: store, productId: rice.id, mode: .decrease)
        viewModel.quantityText = "5"
        viewModel.reason = .distribution
        XCTAssertEqual(viewModel.resultingQuantity, 20)
        XCTAssertNil(viewModel.confirmationReason)
        let outcome = await viewModel.submit()
        XCTAssertNotNil(outcome)
        XCTAssertEqual(repository.adjustRequests.first?.delta, -5)
        XCTAssertEqual(repository.adjustRequests.first?.reason, "distribution")
    }

    func testSignificantDecreaseNeedsConfirmation() {
        let viewModel = AdjustStockViewModel(store: store, productId: rice.id, mode: .decrease)
        viewModel.quantityText = "25"
        XCTAssertEqual(viewModel.confirmationReason, .emptiesStock)
        viewModel.quantityText = "20"
        XCTAssertEqual(viewModel.confirmationReason, .largeDecrease(percent: 80))
    }

    func testExactCountUsesVersionSeenOnOpen() async {
        let viewModel = AdjustStockViewModel(store: store, productId: rice.id, mode: .set)
        XCTAssertEqual(viewModel.quantityText, "25", "count starts from the current quantity")
        viewModel.quantityText = "22"

        // Meanwhile another volunteer changes the stock.
        let index = repository.items.firstIndex { $0.id == rice.id }!
        repository.items[index].stockVersion += 1
        repository.items[index].quantity = 40

        let outcome = await viewModel.submit()
        XCTAssertNil(outcome)
        XCTAssertEqual(viewModel.serverError, .versionConflict)
        XCTAssertEqual(store.item(id: rice.id)?.quantity, 40, "the other volunteer's change is kept and shown")

        // Saving again after reviewing the new value succeeds.
        let retry = await viewModel.submit()
        XCTAssertNotNil(retry)
        XCTAssertEqual(repository.items[index].quantity, 22)
    }

    func testSwitchingModeResetsInput() {
        let viewModel = AdjustStockViewModel(store: store, productId: rice.id, mode: .increase)
        viewModel.quantityText = "7"
        viewModel.reason = .donation
        viewModel.setMode(.decrease)
        XCTAssertEqual(viewModel.quantityText, "")
        XCTAssertNil(viewModel.reason)
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    private var auth: MockAuthService!
    private var profiles: MockProfileRepository!
    private var repository: MockInventoryRepository!
    private var session: SessionStore!
    private let userId = UUID()

    override func setUp() async throws {
        auth = MockAuthService()
        profiles = MockProfileRepository()
        repository = MockInventoryRepository()
        repository.items = Fixtures.sampleInventory
        let localStore = Fixtures.temporaryStore()
        let inventory = InventoryStore(repository: repository, connectivity: MockConnectivity(), localStore: localStore)
        session = SessionStore(auth: auth, profiles: profiles, admin: profiles, inventory: inventory, localStore: localStore)
        session.start()
    }

    override func tearDown() async throws {
        session.inventory.stop()
    }

    /// Emits a sign-in once the session is listening for auth changes.
    private func signIn(email: String? = nil) async {
        await waitUntil { self.auth.isSubscribed }
        auth.emit(.signedIn(userId: userId, email: email))
    }

    private func profile(role: MemberRole, active: Bool = true) -> UserProfile {
        UserProfile(id: userId, displayName: "דנה", role: role, isActive: active, createdAt: Date())
    }

    func testPendingVolunteerMustJoinAndSeesNoInventory() async {
        profiles.profile = profile(role: .pending)
        await signIn(email: "dana@example.org")
        await waitUntil { if case .needsJoin = self.session.state { return true } else { return false } }
        XCTAssertEqual(repository.fetchInventoryCount, 0, "inventory is not loaded before approval")
    }

    func testJoinWithCodeActivatesMembership() async throws {
        profiles.profile = profile(role: .pending)
        await signIn()
        await waitUntil { if case .needsJoin = self.session.state { return true } else { return false } }

        profiles.joinResult = .invalidJoinCode
        do {
            try await session.join(code: "WRONG")
            XCTFail("expected invalid code")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidJoinCode)
        }

        profiles.joinResult = nil
        try await session.join(code: " SAHI-2026 ")
        XCTAssertEqual(profiles.joinCodes.last, "SAHI-2026")
        await waitUntil { if case .active = self.session.state { return true } else { return false } }
        await waitUntil { self.repository.fetchInventoryCount > 0 }
    }

    func testDeactivatedVolunteerLosesAccess() async {
        profiles.profile = profile(role: .volunteer)
        await signIn()
        await waitUntil { if case .active = self.session.state { return true } else { return false } }

        profiles.profile = profile(role: .volunteer, active: false)
        await session.refreshProfile()
        if case .disabled = session.state {} else { XCTFail("expected disabled, got \(session.state)") }
        XCTAssertFalse(session.isAdmin)
    }

    func testAdminFlag() async {
        profiles.profile = profile(role: .admin)
        await signIn()
        await waitUntil { self.session.isAdmin }
    }

    func testSignOutClearsEverything() async {
        profiles.profile = profile(role: .volunteer)
        await signIn()
        await waitUntil { !self.session.inventory.items.isEmpty }
        await session.signOut()
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertTrue(session.inventory.items.isEmpty)
        XCTAssertTrue(auth.signedOut)
    }
}
