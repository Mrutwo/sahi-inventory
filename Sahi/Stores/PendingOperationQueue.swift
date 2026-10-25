import Foundation
import Observation

/// A stock change made while offline, waiting to be sent.
struct PendingOperation: Codable, Hashable, Identifiable, Sendable {
    enum Payload: Codable, Hashable, Sendable {
        case add(AddStockRequest)
        case adjust(AdjustStockRequest)
    }

    let payload: Payload
    let productName: String
    let unitCode: String
    let createdAt: Date
    /// Set when the server rejected the change (e.g. not enough stock);
    /// such operations are not retried and wait for the volunteer to dismiss them.
    var failureMessage: String?

    /// The request id doubles as the identity: replays are idempotent on the server.
    var id: UUID {
        switch payload {
        case .add(let request): return request.requestId
        case .adjust(let request): return request.requestId
        }
    }

    var delta: Decimal {
        switch payload {
        case .add(let request): return request.quantity
        case .adjust(let request): return request.delta
        }
    }

    var productId: UUID? {
        if case .adjust(let request) = payload { return request.productId }
        return nil
    }
}

/// Offline queue for additive stock changes (add / increase / decrease).
/// Only changes that commute are queued; edits, exact counts and removals
/// need a connection so they can be checked against the latest data.
@MainActor
@Observable
final class PendingOperationQueue {
    private(set) var operations: [PendingOperation] = []

    @ObservationIgnored private let localStore: LocalStore
    @ObservationIgnored private var fileName: String?

    init(localStore: LocalStore) {
        self.localStore = localStore
    }

    var waiting: [PendingOperation] { operations.filter { $0.failureMessage == nil } }
    var failed: [PendingOperation] { operations.filter { $0.failureMessage != nil } }
    var isEmpty: Bool { operations.isEmpty }

    /// Loads the queue belonging to a user (each account has its own file).
    func load(userId: UUID) {
        let name = "pending-\(userId.uuidString.lowercased()).json"
        fileName = name
        operations = localStore.load([PendingOperation].self, from: name) ?? []
    }

    func unload() {
        fileName = nil
        operations = []
    }

    func clearStoredQueue(userId: UUID) {
        localStore.remove("pending-\(userId.uuidString.lowercased()).json")
    }

    func enqueue(_ operation: PendingOperation) {
        guard !operations.contains(where: { $0.id == operation.id }) else { return }
        operations.append(operation)
        persist()
    }

    func remove(id: UUID) {
        operations.removeAll { $0.id == id }
        persist()
    }

    /// Sum of waiting changes for a product, shown as "+10 ממתין".
    func pendingDelta(for item: InventoryItem) -> Decimal {
        waiting.reduce(Decimal(0)) { total, operation in
            switch operation.payload {
            case .adjust(let request) where request.productId == item.id:
                return total + request.delta
            case .add(let request)
                where request.unitCode == item.unitCode
                    && ProductNameNormalizer.key(request.name) == item.nameKey:
                return total + request.quantity
            default:
                return total
            }
        }
    }

    /// Sends waiting operations in order. Stops at the first connectivity
    /// failure (everything stays queued); server rejections are marked failed.
    /// - Returns: true if at least one operation reached the server.
    func flush(using repository: InventoryRepository) async -> Bool {
        var delivered = false
        for operation in waiting {
            do {
                switch operation.payload {
                case .add(let request): _ = try await repository.addStock(request)
                case .adjust(let request): _ = try await repository.adjustStock(request)
                }
                remove(id: operation.id)
                delivered = true
            } catch {
                let appError = (error as? AppError) ?? AppError.fromGeneric(error)
                if appError.isConnectivityProblem {
                    Log.sync.info("Flush paused: still offline")
                    break
                }
                Log.sync.error("Queued change rejected: \(appError.localizedDescription, privacy: .public)")
                if let index = operations.firstIndex(where: { $0.id == operation.id }) {
                    operations[index].failureMessage = appError.localizedDescription
                    persist()
                }
            }
        }
        return delivered
    }

    private func persist() {
        guard let fileName else { return }
        if operations.isEmpty {
            localStore.remove(fileName)
        } else {
            localStore.save(operations, to: fileName)
        }
    }
}
