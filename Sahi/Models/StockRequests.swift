import Foundation

// Parameters for the stock RPC functions. Property names match the SQL
// parameter names so they encode directly as the RPC body.

struct AddStockRequest: Codable, Hashable, Sendable {
    var name: String
    var unitCode: String
    var quantity: Decimal
    var categoryId: UUID?
    var notes: String?
    var variant: String = ""
    /// Idempotency key: retries with the same id are applied once.
    var requestId: UUID = UUID()

    enum CodingKeys: String, CodingKey {
        case name = "p_name"
        case unitCode = "p_unit_code"
        case quantity = "p_quantity"
        case categoryId = "p_category_id"
        case notes = "p_notes"
        case variant = "p_variant"
        case requestId = "p_request_id"
    }
}

struct AdjustStockRequest: Codable, Hashable, Sendable {
    var productId: UUID
    /// Positive to add stock, negative to remove it.
    var delta: Decimal
    var reason: String?
    var requestId: UUID = UUID()

    enum CodingKeys: String, CodingKey {
        case productId = "p_product_id"
        case delta = "p_delta"
        case reason = "p_reason"
        case requestId = "p_request_id"
    }
}

struct SetStockRequest: Codable, Hashable, Sendable {
    var productId: UUID
    var newQuantity: Decimal
    /// The stock version the user was looking at; a newer one means a conflict.
    var expectedVersion: Int
    var reason: String?
    var requestId: UUID = UUID()

    enum CodingKeys: String, CodingKey {
        case productId = "p_product_id"
        case newQuantity = "p_new_quantity"
        case expectedVersion = "p_expected_version"
        case reason = "p_reason"
        case requestId = "p_request_id"
    }
}

struct UpdateProductRequest: Codable, Hashable, Sendable {
    var productId: UUID
    var expectedVersion: Int
    var name: String
    var categoryId: UUID?
    var unitCode: String
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case productId = "p_product_id"
        case expectedVersion = "p_expected_version"
        case name = "p_name"
        case categoryId = "p_category_id"
        case unitCode = "p_unit_code"
        case notes = "p_notes"
    }

    // p_category_id has no default on the server, so nil must be sent as null
    // rather than omitted (synthesized encoding would omit it).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(productId, forKey: .productId)
        try container.encode(expectedVersion, forKey: .expectedVersion)
        try container.encode(name, forKey: .name)
        try container.encode(categoryId, forKey: .categoryId)
        try container.encode(unitCode, forKey: .unitCode)
        try container.encode(notes, forKey: .notes)
    }
}

/// Result of a stock change, as returned by the server.
struct StockChangeResult: Codable, Hashable, Sendable {
    let movementId: Int64?
    let productId: UUID
    let kind: ActivityEntry.Kind
    let quantityDelta: Decimal
    let previousQuantity: Decimal?
    let newQuantity: Decimal?
    /// True when the server recognised the request id and did not apply it again.
    let replayed: Bool

    enum CodingKeys: String, CodingKey {
        case movementId = "movement_id"
        case productId = "product_id"
        case kind
        case quantityDelta = "quantity_delta"
        case previousQuantity = "previous_quantity"
        case newQuantity = "new_quantity"
        case replayed
    }
}

/// Why stock was removed or added. Stored on the server as the code so the
/// label can be translated; free text is stored as-is.
enum StockReason: String, CaseIterable, Identifiable, Sendable {
    case donation
    case purchase
    case distribution
    case expired
    case damaged
    case correction
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .donation: return String(localized: "תרומה")
        case .purchase: return String(localized: "רכישה")
        case .distribution: return String(localized: "חלוקה למשפחות")
        case .expired: return String(localized: "פג תוקף")
        case .damaged: return String(localized: "נזק")
        case .correction: return String(localized: "תיקון טעות")
        case .other: return String(localized: "אחר")
        }
    }

    static let forIncrease: [StockReason] = [.donation, .purchase, .correction, .other]
    static let forDecrease: [StockReason] = [.distribution, .expired, .damaged, .correction, .other]

    /// Builds the stored reason text: "code" or "code: note".
    static func encode(_ reason: StockReason?, note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (reason, trimmed.isEmpty) {
        case (nil, true): return nil
        case (nil, false): return trimmed
        case let (reason?, true): return reason.rawValue
        case let (reason?, false): return "\(reason.rawValue): \(trimmed)"
        }
    }

    /// Turns a stored reason back into display text.
    static func display(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        let parts = stored.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = parts.first, let reason = StockReason(rawValue: first) {
            return parts.count > 1 && !parts[1].isEmpty ? "\(reason.title): \(parts[1])" : reason.title
        }
        return stored
    }
}
