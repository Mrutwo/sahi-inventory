import Foundation

/// Turns a stock movement into a readable Hebrew sentence, e.g.
/// "נוספו 10 יחידות אורז" or "הכמות של שמן עודכנה מ-12 ל-18".
enum ActivityDescriber {
    static func sentence(for entry: ActivityEntry, units: [String: MeasurementUnit], includeProduct: Bool = true) -> String {
        let unit = units[entry.unitCode] ?? .unknown(entry.unitCode)
        let name = entry.productName
        let amount = QuantityFormatter.string(abs(entry.quantityDelta))
        let unitName = unit.displayName
        let previous = entry.previousQuantity.map(QuantityFormatter.string) ?? "0"
        let new = entry.newQuantity.map(QuantityFormatter.string) ?? "0"

        switch entry.kind {
        case .create:
            return includeProduct
                ? String(localized: "מוצר חדש: נוספו \(amount) \(unitName) \(name)")
                : String(localized: "המוצר נוצר עם \(amount) \(unitName)")
        case .increase:
            return includeProduct
                ? String(localized: "נוספו \(amount) \(unitName) \(name)")
                : String(localized: "נוספו \(amount) \(unitName)")
        case .decrease:
            return includeProduct
                ? String(localized: "הוצאו \(amount) \(unitName) \(name)")
                : String(localized: "הוצאו \(amount) \(unitName)")
        case .set:
            return includeProduct
                ? String(localized: "הכמות של \(name) עודכנה מ-\(previous) ל-\(new)")
                : String(localized: "הכמות עודכנה מ-\(previous) ל-\(new)")
        case .edit:
            if let change = entry.details?.name, let from = change.from, let to = change.to {
                return String(localized: "שם המוצר שונה מ\"\(from)\" ל\"\(to)\"")
            }
            if let change = entry.details?.category, let to = change.to {
                return includeProduct
                    ? String(localized: "הקטגוריה של \(name) שונתה ל\(to)")
                    : String(localized: "הקטגוריה שונתה ל\(to)")
            }
            return includeProduct
                ? String(localized: "פרטי המוצר \(name) עודכנו")
                : String(localized: "פרטי המוצר עודכנו")
        case .unitChange:
            let from = entry.details?.unit?.from.map { (units[$0] ?? .unknown($0)).displayName } ?? ""
            return includeProduct
                ? String(localized: "יחידת המידה של \(name) שונתה מ\(from) ל\(unitName) (\(previous) ← \(new))")
                : String(localized: "יחידת המידה שונתה מ\(from) ל\(unitName) (\(previous) ← \(new))")
        case .archive:
            return includeProduct
                ? String(localized: "\(name) הוסר מהמלאי הפעיל")
                : String(localized: "המוצר הוסר מהמלאי הפעיל")
        case .restore:
            return includeProduct
                ? String(localized: "\(name) הוחזר למלאי")
                : String(localized: "המוצר הוחזר למלאי")
        case .unknown:
            return includeProduct
                ? String(localized: "עדכון במוצר \(name)")
                : String(localized: "עדכון במוצר")
        }
    }

    /// Extra detail lines for edits ("קטגוריה: שימורים ← מוצרי יסוד").
    static func detailLines(for entry: ActivityEntry) -> [String] {
        guard let details = entry.details else { return [] }
        var lines: [String] = []
        if let change = details.name {
            lines.append(String(localized: "שם: \(change.from ?? "—") ← \(change.to ?? "—")"))
        }
        if let change = details.category {
            lines.append(String(localized: "קטגוריה: \(change.from ?? "—") ← \(change.to ?? "—")"))
        }
        if details.notes != nil {
            lines.append(String(localized: "ההערות עודכנו"))
        }
        return lines
    }
}
