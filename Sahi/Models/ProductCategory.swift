import Foundation
import UIKit

struct ProductCategory: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let slug: String
    let nameHe: String
    let nameEn: String?
    let nameRu: String?
    let icon: String
    let sortOrder: Int
    let isActive: Bool

    var displayName: String {
        LocalizedName.pick(he: nameHe, en: nameEn, ru: nameRu)
    }

    /// SF Symbol for the category; falls back to a generic box if the server
    /// names a symbol this iOS version does not have.
    var symbolName: String {
        UIImage(systemName: icon) != nil ? icon : "shippingbox"
    }

    var isOther: Bool { slug == "other" }

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case nameHe = "name_he"
        case nameEn = "name_en"
        case nameRu = "name_ru"
        case icon
        case sortOrder = "sort_order"
        case isActive = "is_active"
    }
}
