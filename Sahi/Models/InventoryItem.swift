import Foundation

/// One product with its current stock, as served by the `inventory_items` view.
struct InventoryItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var nameKey: String
    var variant: String
    var categoryId: UUID?
    var unitCode: String
    var notes: String?
    var isActive: Bool
    var quantity: Decimal
    /// Optimistic-concurrency version of the product details (name, unit, …).
    var productVersion: Int
    /// Optimistic-concurrency version of the stock quantity.
    var stockVersion: Int
    var createdAt: Date
    var updatedAt: Date
    var updatedByName: String?

    var isOutOfStock: Bool { quantity <= 0 }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameKey = "name_key"
        case variant
        case categoryId = "category_id"
        case unitCode = "unit_code"
        case notes
        case isActive = "is_active"
        case quantity
        case productVersion = "product_version"
        case stockVersion = "stock_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedByName = "updated_by_name"
    }
}
