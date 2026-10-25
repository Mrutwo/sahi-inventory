import Foundation

/// Client-side validation with Hebrew messages. The server repeats every check;
/// this layer exists so volunteers get instant, clear feedback.
enum ValidationIssue: Error, Equatable, Sendable {
    case nameEmpty
    case nameTooLong
    case quantityEmpty
    case quantityInvalid
    case quantityNotPositive
    case quantityNegative
    case quantityTooLarge
    case quantityTooManyDecimals
    case quantityNotWhole(unitName: String)
    case unitMissing
    case notesTooLong
    case insufficientStock(available: String)

    var message: String {
        switch self {
        case .nameEmpty: return String(localized: "יש להזין שם מוצר")
        case .nameTooLong: return String(localized: "שם המוצר ארוך מדי (עד 120 תווים)")
        case .quantityEmpty: return String(localized: "יש להזין כמות")
        case .quantityInvalid: return String(localized: "הכמות צריכה להיות מספר, למשל 10 או 2.5")
        case .quantityNotPositive: return String(localized: "הכמות צריכה להיות גדולה מאפס")
        case .quantityNegative: return String(localized: "הכמות לא יכולה להיות שלילית")
        case .quantityTooLarge: return String(localized: "הכמות גדולה מדי")
        case .quantityTooManyDecimals: return String(localized: "אפשר עד 3 ספרות אחרי הנקודה")
        case .quantityNotWhole(let unitName): return String(localized: "ב\(unitName) יש להזין מספר שלם")
        case .unitMissing: return String(localized: "יש לבחור יחידת מידה")
        case .notesTooLong: return String(localized: "ההערה ארוכה מדי (עד 500 תווים)")
        case .insufficientStock(let available): return String(localized: "אין מספיק במלאי (זמין: \(available))")
        }
    }
}

enum ProductValidator {
    static let maxNameLength = 120
    static let maxNotesLength = 500
    static let maxQuantity: Decimal = 1_000_000

    static func validateName(_ name: String) -> ValidationIssue? {
        let clean = ProductNameNormalizer.displayName(name)
        if clean.isEmpty { return .nameEmpty }
        if clean.count > maxNameLength { return .nameTooLong }
        return nil
    }

    static func validateNotes(_ notes: String) -> ValidationIssue? {
        notes.trimmingCharacters(in: .whitespacesAndNewlines).count > maxNotesLength ? .notesTooLong : nil
    }

    /// Validates a typed quantity for `unit`.
    /// - Parameter allowZero: true for an exact stock count (which may be 0).
    static func validateQuantity(_ text: String, unit: MeasurementUnit?, allowZero: Bool = false) -> Result<Decimal, ValidationIssue> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.quantityEmpty) }
        if trimmed.hasPrefix("-") { return .failure(.quantityNegative) }
        guard let parsed = QuantityParser.parse(trimmed) else { return .failure(.quantityInvalid) }
        if parsed.value == 0 && !allowZero { return .failure(.quantityNotPositive) }
        if parsed.value > maxQuantity { return .failure(.quantityTooLarge) }
        if let unit, !unit.allowsFractions, parsed.value != parsed.value.sahiRounded(scale: 0) {
            return .failure(.quantityNotWhole(unitName: unit.displayName))
        }
        if parsed.fractionDigits > 3 { return .failure(.quantityTooManyDecimals) }
        return .success(parsed.value)
    }
}

extension Decimal {
    func sahiRounded(scale: Int, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var copy = self
        var result = Decimal()
        NSDecimalRound(&result, &copy, scale, mode)
        return result
    }
}
