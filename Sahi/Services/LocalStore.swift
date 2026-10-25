import Foundation

/// Small JSON file store in Application Support, used for the offline cache
/// of the last inventory snapshot and for queued offline changes. This is a
/// cache only — the cloud database remains the source of truth.
struct LocalStore: Sendable {
    let directory: URL

    static let standard: LocalStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LocalStore(directory: base.appendingPathComponent("Sahi", isDirectory: true))
    }()

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONCoding.cacheDecoder.decode(T.self, from: data)
        } catch {
            Log.sync.error("Discarding unreadable cache \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, to name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONCoding.cacheEncoder.encode(value)
            try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.sync.error("Failed to write cache \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

/// Last known inventory, shown immediately on launch and while offline.
struct InventorySnapshot: Codable, Sendable {
    var userId: UUID
    var items: [InventoryItem]
    var units: [MeasurementUnit]
    var categories: [ProductCategory]
    var savedAt: Date

    static let fileName = "inventory-cache.json"
}

extension JSONCoding {
    /// Cache files are written and read by the app itself, so a numeric date format suffices.
    static let cacheEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
