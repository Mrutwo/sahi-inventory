import XCTest
@testable import Sahi

@MainActor
final class InventoryStoreTests: XCTestCase {
    private var repository: MockInventoryRepository!
    private var connectivity: MockConnectivity!
    private var store: InventoryStore!

    override func setUp() async throws {
        repository = MockInventoryRepository()
        repository.items = Fixtures.sampleInventory
        connectivity = MockConnectivity()
        store = InventoryStore(repository: repository, connectivity: connectivity, localStore: Fixtures.temporaryStore())
    }

    override func tearDown() async throws {
        store.stop()
    }

    func testRefreshLoadsSharedInventory() async {
        await store.refresh()
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertEqual(store.items.count, 6)
        XCTAssertEqual(store.categories.count, 3)
        XCTAssertNotNil(store.lastSyncedAt)
    }

    func testAddingProductCallsServerAndUpdatesInventory() async throws {
        await store.refresh()
        let request = AddStockRequest(name: "אורז", unitCode: "unit", quantity: 10, categoryId: nil, notes: nil)
        let outcome = try await store.addStock(request)
        guard case .saved(let result) = outcome else { return XCTFail("expected saved") }
        XCTAssertEqual(result.newQuantity, 35)
        XCTAssertEqual(repository.addRequests.count, 1)
        await waitUntil { self.store.item(id: result.productId)?.quantity == 35 }
    }

    func testIncreaseAndDecrease() async throws {
        await store.refresh()
        let rice = try XCTUnwrap(store.items.first { $0.name == "אורז" })
        _ = try await store.adjustStock(AdjustStockRequest(productId: rice.id, delta: 5))
        _ = try await store.adjustStock(AdjustStockRequest(productId: rice.id, delta: -12))
        XCTAssertEqual(repository.adjustRequests.map(\.delta), [5, -12])
        await waitUntil { self.store.item(id: rice.id)?.quantity == 18 }
    }

    func testServerRejectionIsReported() async throws {
        await store.refresh()
        let rice = try XCTUnwrap(store.items.first { $0.name == "אורז" })
        do {
            _ = try await store.adjustStock(AdjustStockRequest(productId: rice.id, delta: -100))
            XCTFail("expected insufficient stock")
        } catch {
            XCTAssertEqual(error as? AppError, .insufficientStock)
        }
        XCTAssertTrue(store.pending.isEmpty, "server rejections are not queued for retry")
    }

    func testOfflineChangesAreQueuedAndSentOnReconnect() async throws {
        store.start(userId: UUID())
        await waitUntil { self.store.loadState == .loaded }
        let tuna = try XCTUnwrap(store.items.first { $0.name == "טונה" })
        connectivity.isOnline = false

        let outcome = try await store.adjustStock(AdjustStockRequest(productId: tuna.id, delta: 5))
        XCTAssertEqual(outcome, .queued)
        XCTAssertTrue(repository.adjustRequests.isEmpty, "nothing may be sent while offline")
        XCTAssertEqual(store.pending.waiting.count, 1)
        XCTAssertEqual(store.pending.pendingDelta(for: tuna), 5)

        connectivity.isOnline = true
        await waitUntil { self.store.pending.isEmpty }
        XCTAssertEqual(repository.adjustRequests.count, 1)
        await waitUntil { self.store.item(id: tuna.id)?.quantity == 37 }
    }

    func testNetworkFailureDuringSaveQueuesTheChange() async throws {
        await store.refresh()
        repository.writeError = URLError(.networkConnectionLost)
        let request = AddStockRequest(name: "קמח", unitCode: "kg", quantity: 2, categoryId: nil, notes: nil)
        let outcome = try await store.addStock(request)
        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(store.pending.waiting.first?.id, request.requestId, "the retry reuses the same idempotency key")
    }

    func testRetryAfterFailureReusesRequestId() async throws {
        await store.refresh()
        connectivity.isOnline = false
        let request = AddStockRequest(name: "קמח", unitCode: "kg", quantity: 2, categoryId: nil, notes: nil)
        _ = try await store.addStock(request)
        _ = try await store.addStock(request)
        XCTAssertEqual(store.pending.waiting.count, 1, "the same request is queued once")
    }

    func testRejectedQueuedChangeIsMarkedFailed() async throws {
        await store.refresh()
        let milk = try XCTUnwrap(store.items.first { $0.name == "חלב" })
        connectivity.isOnline = false
        _ = try await store.adjustStock(AdjustStockRequest(productId: milk.id, delta: -50))
        connectivity.isOnline = true
        await store.flushPending()
        XCTAssertEqual(store.pending.failed.count, 1)
        XCTAssertNotNil(store.pending.failed.first?.failureMessage)
        XCTAssertTrue(store.pending.waiting.isEmpty)
    }

    func testRealtimeChangeFromAnotherVolunteerRefreshesInventory() async throws {
        store.start(userId: UUID())
        await waitUntil { self.store.loadState == .loaded }
        let before = repository.fetchInventoryCount

        // Another device adds pasta; the server notifies this device.
        let pasta = try XCTUnwrap(repository.items.firstIndex { $0.name == "פסטה" })
        repository.items[pasta].quantity = 60
        repository.emit(.tableChanged("inventory"))

        await waitUntil { self.repository.fetchInventoryCount > before }
        await waitUntil { self.store.items.first { $0.name == "פסטה" }?.quantity == 60 }
    }

    func testReconnectCatchesUpOnMissedChanges() async throws {
        store.start(userId: UUID())
        await waitUntil { self.store.loadState == .loaded }
        repository.emit(.connection(true))
        await waitUntil { self.store.isRealtimeConnected }
        repository.emit(.connection(false))
        await waitUntil { !self.store.isRealtimeConnected }
        let before = repository.fetchInventoryCount
        repository.emit(.connection(true))
        await waitUntil { self.repository.fetchInventoryCount > before }
    }

    func testVersionConflictRefreshesAndReports() async throws {
        await store.refresh()
        let oil = try XCTUnwrap(store.items.first { $0.name == "שמן" })
        // Someone else changed the stock after this device loaded it.
        let index = try XCTUnwrap(repository.items.firstIndex { $0.id == oil.id })
        repository.items[index].stockVersion = 2
        repository.items[index].quantity = 20
        let before = repository.fetchInventoryCount

        do {
            _ = try await store.setStock(SetStockRequest(productId: oil.id, newQuantity: 5, expectedVersion: oil.stockVersion))
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? AppError, .versionConflict)
        }
        XCTAssertGreaterThan(repository.fetchInventoryCount, before)
        XCTAssertEqual(store.item(id: oil.id)?.quantity, 20, "the newer value was not overwritten")
    }

    func testEditsRequireConnection() async throws {
        await store.refresh()
        let oil = try XCTUnwrap(store.items.first { $0.name == "שמן" })
        connectivity.isOnline = false
        do {
            try await store.updateProduct(UpdateProductRequest(productId: oil.id, expectedVersion: 1, name: "שמן זית", categoryId: nil, unitCode: "bottle", notes: nil))
            XCTFail("expected offline error")
        } catch {
            XCTAssertEqual(error as? AppError, .offline)
        }
        XCTAssertTrue(repository.updateRequests.isEmpty)
    }

    func testFailedRefreshKeepsLastKnownData() async {
        await store.refresh()
        repository.fetchError = URLError(.notConnectedToInternet)
        await store.refresh()
        XCTAssertEqual(store.items.count, 6)
        XCTAssertEqual(store.refreshError, .offline)
        XCTAssertEqual(store.loadState, .loaded)
    }

    func testFailedFirstLoadShowsError() async {
        repository.fetchError = URLError(.cannotConnectToHost)
        await store.refresh()
        XCTAssertEqual(store.loadState, .failed(.offline))
    }

    func testSnapshotIsRestoredForTheSameUserOnly() async throws {
        let localStore = Fixtures.temporaryStore()
        let userId = UUID()
        let first = InventoryStore(repository: repository, connectivity: connectivity, localStore: localStore)
        first.start(userId: userId)
        await waitUntil { first.loadState == .loaded }
        first.stop()

        repository.fetchError = URLError(.notConnectedToInternet)
        let second = InventoryStore(repository: repository, connectivity: MockConnectivity(isOnline: false), localStore: localStore)
        second.start(userId: userId)
        XCTAssertEqual(second.items.count, 6, "cached inventory is shown immediately while offline")
        second.stop()

        let other = InventoryStore(repository: repository, connectivity: MockConnectivity(isOnline: false), localStore: localStore)
        other.start(userId: UUID())
        XCTAssertTrue(other.items.isEmpty, "another account never sees this cache")
        other.stop()
    }

    func testSearchAndFilterOnStore() async {
        await store.refresh()
        store.filter.searchText = "סוכ"
        XCTAssertEqual(store.visibleItems.map(\.name), ["סוכר"])
        store.filter.reset()
        store.filter.categoryIds = [Fixtures.dairyId]
        XCTAssertEqual(store.visibleItems.map(\.name), ["חלב"])
    }
}
