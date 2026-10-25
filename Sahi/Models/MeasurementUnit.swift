import Foundation

/// A unit of measurement. Units come from the `units` table so new ones can be
/// added without an app update; `defaults` mirrors the seeded rows and is used
/// before the first successful fetch.
struct MeasurementUnit: Codable, Hashable, Identifiable, Sendable {
    enum Dimension: String, Codable, Sendable {
        /// Discrete items (יחידות, קופסאות, בקבוקים, חבילות). Never converted into each other.
        case count
        /// Weight; base unit is the gram.
        case mass
        /// Volume; base unit is the milliliter.
        case volume
    }

    let code: String
    let nameHe: String
    let nameEn: String?
    let nameRu: String?
    let dimension: Dimension
    /// Size of one unit in the dimension's base unit (kg = 1000 g).
    let baseFactor: Decimal
    let sortOrder: Int
    let isActive: Bool

    var id: String { code }

    var displayName: String {
        LocalizedName.pick(he: nameHe, en: nameEn, ru: nameRu)
    }

    /// Count units must be whole numbers; weight and volume may be fractional.
    var allowsFractions: Bool { dimension != .count }

    /// Whether stock in this unit can be converted into `other` without
    /// mixing incompatible quantities. Mirrors the server's update_product rule.
    func canConvert(to other: MeasurementUnit) -> Bool {
        code == other.code || (dimension == other.dimension && dimension != .count)
    }

    enum CodingKeys: String, CodingKey {
        case code
        case nameHe = "name_he"
        case nameEn = "name_en"
        case nameRu = "name_ru"
        case dimension
        case baseFactor = "base_factor"
        case sortOrder = "sort_order"
        case isActive = "is_active"
    }
}

extension MeasurementUnit {
    static let defaults: [MeasurementUnit] = [
        MeasurementUnit(code: "unit", nameHe: "יחידות", nameEn: "units", nameRu: "шт.", dimension: .count, baseFactor: 1, sortOrder: 10, isActive: true),
        MeasurementUnit(code: "box", nameHe: "קופסאות", nameEn: "cans/boxes", nameRu: "банки", dimension: .count, baseFactor: 1, sortOrder: 20, isActive: true),
        MeasurementUnit(code: "bottle", nameHe: "בקבוקים", nameEn: "bottles", nameRu: "бутылки", dimension: .count, baseFactor: 1, sortOrder: 30, isActive: true),
        MeasurementUnit(code: "package", nameHe: "חבילות", nameEn: "packages", nameRu: "упаковки", dimension: .count, baseFactor: 1, sortOrder: 40, isActive: true),
        MeasurementUnit(code: "kg", nameHe: "ק\"ג", nameEn: "kg", nameRu: "кг", dimension: .mass, baseFactor: 1000, sortOrder: 50, isActive: true),
        MeasurementUnit(code: "g", nameHe: "גרם", nameEn: "g", nameRu: "г", dimension: .mass, baseFactor: 1, sortOrder: 60, isActive: true),
        MeasurementUnit(code: "liter", nameHe: "ליטרים", nameEn: "liters", nameRu: "л", dimension: .volume, baseFactor: 1000, sortOrder: 70, isActive: true),
    ]

    /// Fallback for a unit code the app does not know (e.g. added on the server
    /// after this build); shows the raw code rather than failing.
    static func unknown(_ code: String) -> MeasurementUnit {
        MeasurementUnit(code: code, nameHe: code, nameEn: nil, nameRu: nil, dimension: .count, baseFactor: 1, sortOrder: .max, isActive: false)
    }
}

/// Picks the name matching the app's current language, falling back to Hebrew.
enum LocalizedName {
    static func pick(he: String, en: String?, ru: String?) -> String {
        switch AppLocale.languageCode {
        case "en": return en ?? he
        case "ru": return ru ?? he
        default: return he
        }
    }
}
