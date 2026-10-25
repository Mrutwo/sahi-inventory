import Foundation
import Observation

/// The shared inventory as seen by this device.
///
/// * Loads from the cloud, keeps a local snapshot for instant start-up and
///   offline viewing (cache only — the server is the source of truth).
/// * Subscribes to realtime changes and re-fetches (debounced) whenever any
///   volunteer changes something, and after every reconnect, so missed events
///   are always caught up.
/// * Sends writes to the server functions; additive changes made offline are
///   queued and delivered automatically when the connection returns.
@MainActor
@Observable
final class InventoryStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(AppError)
    }

    enum MutationOutcome: Equatable {
        case saved(StockChangeResult)
        /// No connection: the change was queued and will be sent automatically.
        case queued
    }

    private(set) var items: [InventoryItem] = []
    private(set) var units: [MeasurementUnit] = MeasurementUnit.defaults
    private(set) var categories: [ProductCategory] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var isRealtimeConnected = false
    /// Last refresh failed; the list shows the most recent data we have.
    private(set) var refreshError: AppError?
    /// Bumped on every remote change so open screens (details, history) reload.
    private(set) var changeToken = 0
    var filter = InventoryFilter()

    let pending: PendingOperationQueue

    /// Called when the server reports an access problem or a profile changed,
    /// so the session can re-check the volunteer's membership.
    @ObservationIgnored var onMembershipShouldRefresh: (@MainActor () -> Void)?

    @ObservationIgnored private let repository: InventoryRepository
    @ObservationIgnored private let connectivity: ConnectivityProviding
    @ObservationIgnored private let localStore: LocalStore
    @ObservationIgnored private var userId: UUID?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var referenceDataLoaded = false
    @ObservationIgnored private var isFlushing = false

    init(repository: InventoryRepository, connectivity: ConnectivityProviding, localStore: LocalStore = .standard) {
        self.repository = repository
        self.connectivity = connectivity
        self.localStore = localStore
        self.pending = PendingOperationQueue(localStore: localStore)
    }

    // MARK: - Derived data

    var unitsByCode: [String: MeasurementUnit] {
        Dictionary(units.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var categoriesById: [UUID: ProductCategory] {
        Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var activeUnits: [MeasurementUnit] { units.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder } }
    var activeCategories: [ProductCategory] { categories.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder } }

    var visibleItems: [InventoryItem] { InventoryQuery.apply(filter, to: items) }
    var totals: InventoryTotals { InventoryTotals.compute(items: items, units: unitsByCode) }
    var isOnline: Bool { connectivity.isOnline }
    var isShowingStaleData: Bool { !isOnline || refreshError != nil }

    func unit(for code: String) -> MeasurementUnit { unitsByCode[code] ?? .unknown(code) }
    func category(for id: UUID?) -> ProductCategory? { id.flatMap { categoriesById[$0] } }
    func item(id: UUID) -> InventoryItem? { items.first { $0.id == id } }

    // MARK: - Lifecycle

    /// Starts syncing for the signed-in volunteer.
    func start(userId: UUID) {
        if self.userId == userId, !tasks.isEmpty { return }
        stop()
        self.userId = userId
        restoreSnapshot(for: userId)
        pending.load(userId: userId)

        tasks.append(Task { [weak self] in
            await self?.refresh()
            await self?.flushPending()
        })
        tasks.append(Task { [weak self] in
            guard let events = self?.repository.realtimeEvents() else { return }
            for await event in events {
                self?.handle(event)
            }
        })
        tasks.append(Task { [weak self] in
            guard let updates = self?.connectivity.updates() else { return }
            for await online in updates where online {
                await self?.flushPending()
                self?.scheduleRefresh(after: .zero)
            }
        })
    }

    /// Stops syncing (e.g. membership revoked) but keeps what is on screen.
    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        debounceTask?.cancel()
        debounceTask = nil
        isRealtimeConnected = false
    }

    /// Clears everything for sign-out, including the local cache.
    func reset(clearingCacheFor userId: UUID?) {
        stop()
        if let userId {
            localStore.remove(InventorySnapshot.fileName)
            pending.clearStoredQueue(userId: userId)
        }
        pending.unload()
        self.userId = nil
        items = []
        categories = []
        units = MeasurementUnit.defaults
        loadState = .idle
        lastSyncedAt = nil
        refreshError = nil
        referenceDataLoaded = false
        filter = InventoryFilter()
    }

    /// Called when the app returns to the foreground.
    func resume() {
        guard userId != nil else { return }
        scheduleRefresh(after: .zero)
        Task { await flushPending() }
    }

    // MARK: - Loading

    func refresh() async {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await performRefresh()
        } while refreshAgain
    }

    func scheduleRefresh(after delay: Duration = .milliseconds(350)) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            // Run the refresh outside the debounce task so a later debounce
            // cannot cancel a request that is already in flight.
            Task { await self?.refresh() }
        }
    }

    private func performRefresh() async {
        if items.isEmpty, loadState != .loaded {
            loadState = .loading
        }
        let repository = self.repository
        do {
            if !referenceDataLoaded {
                async let fetchedUnits = repository.fetchUnits()
                async let fetchedCategories = repository.fetchCategories()
                let (newUnits, newCategories) = try await (fetchedUnits, fetchedCategories)
                if !newUnits.isEmpty { units = newUnits }
                categories = newCategories
                referenceDataLoaded = true
            }
            items = try await repository.fetchInventory(includeArchived: false)
            loadState = .loaded
            lastSyncedAt = Date()
            refreshError = nil
            saveSnapshot()
        } catch is CancellationError {
            return
        } catch {
            let appError = (error as? AppError) ?? AppError.fromGeneric(error)
            Log.inventory.error("Refresh failed: \(appError.localizedDescription, privacy: .public)")
            refreshError = appError
            if items.isEmpty {
                loadState = .failed(appError)
            }
            if [.notMember, .accountDisabled, .notAuthenticated].contains(appError) {
                onMembershipShouldRefresh?()
            }
        }
    }

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .tableChanged(let table):
            changeToken += 1
            if table == "categories" {
                referenceDataLoaded = false
            }
            if table == "profiles" {
                onMembershipShouldRefresh?()
            }
            scheduleRefresh()
        case .connection(let connected):
            let wasConnected = isRealtimeConnected
            isRealtimeConnected = connected
            if connected, !wasConnected {
                // (Re)connected: catch up on anything missed while disconnected.
                changeToken += 1
                scheduleRefresh(after: .zero)
            }
        }
    }

    // MARK: - Cache

    private func restoreSnapshot(for userId: UUID) {
        guard items.isEmpty,
              let snapshot = localStore.load(InventorySnapshot.self, from: InventorySnapshot.fileName),
              snapshot.userId == userId
        else { return }
        items = snapshot.items
        if !snapshot.units.isEmpty { units = snapshot.units }
        categories = snapshot.categories
        lastSyncedAt = snapshot.savedAt
        loadState = .loaded
    }

    private func saveSnapshot() {
        guard let userId else { return }
        let snapshot = InventorySnapshot(userId: userId, items: items, units: units, categories: categories, savedAt: Date())
        localStore.save(snapshot, to: InventorySnapshot.fileName)
    }

    // MARK: - Writes

    /// Adds stock by name — creates the product or increases the existing one.
    func addStock(_ request: AddStockRequest) async throws -> MutationOutcome {
        let operation = PendingOperation(
            payload: .add(request), productName: request.name, unitCode: request.unitCode,
            createdAt: Date(), failureMessage: nil)
        guard isOnline else {
            pending.enqueue(operation)
            return .queued
        }
        do {
            let result = try await repository.addStock(request)
            applyLocally(result)
            scheduleRefresh(after: .zero)
            return .saved(result)
        } catch {
            return try queueIfOffline(error, operation: operation)
        }
    }

    /// Increases (positive) or decreases (negative) the stock of a product.
    func adjustStock(_ request: AdjustStockRequest) async throws -> MutationOutcome {
        let existing = self.item(id: request.productId)
        let operation = PendingOperation(
            payload: .adjust(request), productName: existing?.name ?? "", unitCode: existing?.unitCode ?? "",
            createdAt: Date(), failureMessage: nil)
        guard isOnline else {
            pending.enqueue(operation)
            return .queued
        }
        do {
            let result = try await repository.adjustStock(request)
            applyLocally(result)
            scheduleRefresh(after: .zero)
            return .saved(result)
        } catch {
            return try queueIfOffline(error, operation: operation)
        }
    }

    /// Sets an exact count. Fails with `.versionConflict` if the stock changed
    /// since `expectedVersion`; the data is refreshed so the volunteer can retry.
    func setStock(_ request: SetStockRequest) async throws -> StockChangeResult {
        try requireOnline()
        do {
            let result = try await repository.setStock(request)
            applyLocally(result)
            scheduleRefresh(after: .zero)
            return result
        } catch {
            throw await handleWriteError(error)
        }
    }

    func updateProduct(_ request: UpdateProductRequest) async throws {
        try requireOnline()
        do {
            try await repository.updateProduct(request)
            await refresh()
        } catch {
            throw await handleWriteError(error)
        }
    }

    func archiveProduct(id: UUID, reason: String?) async throws {
        try requireOnline()
        do {
            try await repository.archiveProduct(id: id, reason: reason)
            items.removeAll { $0.id == id }
            scheduleRefresh(after: .zero)
        } catch {
            throw await handleWriteError(error)
        }
    }

    func restoreProduct(id: UUID) async throws {
        try requireOnline()
        do {
            try await repository.restoreProduct(id: id)
            await refresh()
        } catch {
            throw await handleWriteError(error)
        }
    }

    func fetchArchivedProducts() async throws -> [InventoryItem] {
        try await repository.fetchInventory(includeArchived: true).filter { !$0.isActive }
    }

    func fetchActivity(productId: UUID? = nil, limit: Int = 100) async throws -> [ActivityEntry] {
        try await repository.fetchActivity(productId: productId, limit: limit)
    }

    func flushPending() async {
        guard isOnline, !pending.waiting.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        if await pending.flush(using: repository) {
            scheduleRefresh(after: .zero)
        }
    }

    // MARK: - Helpers

    private func requireOnline() throws {
        guard isOnline else { throw AppError.offline }
    }

    private func queueIfOffline(_ error: Error, operation: PendingOperation) throws -> MutationOutcome {
        let appError = (error as? AppError) ?? AppError.fromGeneric(error)
        if appError.isConnectivityProblem {
            pending.enqueue(operation)
            return .queued
        }
        if [.notMember, .accountDisabled, .notAuthenticated].contains(appError) {
            onMembershipShouldRefresh?()
        }
        throw appError
    }

    private func handleWriteError(_ error: Error) async -> AppError {
        let appError = (error as? AppError) ?? AppError.fromGeneric(error)
        switch appError {
        case .versionConflict, .productNotFound, .productArchived, .duplicateProduct:
            await refresh()
        case .notMember, .accountDisabled, .notAuthenticated:
            onMembershipShouldRefresh?()
        default:
            break
        }
        return appError
    }

    /// Shows a confirmed change immediately, before the refresh completes.
    private func applyLocally(_ result: StockChangeResult) {
        guard let newQuantity = result.newQuantity,
              let index = items.firstIndex(where: { $0.id == result.productId })
        else { return }
        items[index].quantity = newQuantity
        items[index].updatedAt = Date()
    }
}
