import Foundation

/// One row of the append-only stock history (`activity_feed` view).
struct ActivityEntry: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case create
        case increase
        case decrease
        case set
        case edit
        case unitChange = "unit_change"
        case archive
        case restore
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    struct Change: Codable, Hashable, Sendable {
        let from: String?
        let to: String?
    }

    struct Details: Codable, Hashable, Sendable {
        let name: Change?
        let category: Change?
        let notes: Change?
        let unit: Change?
    }

    let id: Int64
    let productId: UUID
    let productName: String
    let kind: Kind
    let quantityDelta: Decimal
    let previousQuantity: Decimal?
    let newQuantity: Decimal?
    let unitCode: String
    let reason: String?
    let details: Details?
    let createdAt: Date
    let createdBy: UUID?
    let actorName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case productId = "product_id"
        case productName = "product_name"
        case kind
        case quantityDelta = "quantity_delta"
        case previousQuantity = "previous_quantity"
        case newQuantity = "new_quantity"
        case unitCode = "unit_code"
        case reason
        case details
        case createdAt = "created_at"
        case createdBy = "created_by"
        case actorName = "actor_name"
    }
}
