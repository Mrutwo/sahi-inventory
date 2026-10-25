import Foundation
import Network
import Observation

@MainActor
protocol ConnectivityProviding: AnyObject {
    var isOnline: Bool { get }
    /// Emits whenever connectivity changes.
    func updates() -> AsyncStream<Bool>
}

/// Watches the device's network path.
@MainActor
@Observable
final class NetworkMonitor: ConnectivityProviding {
    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.update(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.sahi.inventory.network"))
    }

    deinit {
        monitor.cancel()
    }

    func updates() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations[id] = nil
            }
        }
        return stream
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        Log.sync.info("Connectivity changed: \(online ? "online" : "offline", privacy: .public)")
        for continuation in continuations.values {
            continuation.yield(online)
        }
    }
}
