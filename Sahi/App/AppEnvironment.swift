import Foundation

/// Composition root: builds the live services once at launch.
@MainActor
final class AppEnvironment {
    enum Mode {
        /// Backend settings are missing; the app explains how to configure them.
        case notConfigured
        /// Hosted inside the unit-test runner; no UI services are started.
        case testing
        case live(SessionStore)
    }

    let mode: Mode
    let toasts = ToastCenter()
    let network: NetworkMonitor

    init(mode: Mode, network: NetworkMonitor) {
        self.mode = mode
        self.network = network
    }

    static func live() -> AppEnvironment {
        let network = NetworkMonitor()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return AppEnvironment(mode: .testing, network: network)
        }
        guard let config = AppConfig.load() else {
            Log.auth.error("Supabase is not configured (see Config/Secrets.example.xcconfig)")
            return AppEnvironment(mode: .notConfigured, network: network)
        }
        let backend = SupabaseBackend(config: config)
        let inventory = InventoryStore(repository: backend, connectivity: network)
        let session = SessionStore(auth: backend, profiles: backend, admin: backend, inventory: inventory)
        session.start()
        return AppEnvironment(mode: .live(session), network: network)
    }
}
