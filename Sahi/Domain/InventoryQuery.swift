import Foundation

/// Search, filter and sort settings for the inventory list.
struct InventoryFilter: Equatable, Sendable {
    enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case alphabetical
        case recentlyUpdated
        case quantityDescending
        case quantityAscending

        var id: String { rawValue }

        var title: String {
            switch self {
            case .alphabetical: return String(localized: "לפי א-ב")
            case .recentlyUpdated: return String(localized: "עודכנו לאחרונה")
            case .quantityDescending: return String(localized: "כמות: מהגבוהה לנמוכה")
            case .quantityAscending: return String(localized: "כמות: מהנמוכה לגבוהה")
            }
        }

        var symbol: String {
            switch self {
            case .alphabetical: return "textformat"
            case .recentlyUpdated: return "clock"
            case .quantityDescending: return "arrow.down"
            case .quantityAscending: return "arrow.up"
            }
        }
    }

    enum RecentWindow: String, CaseIterable, Identifiable, Sendable {
        case any
        case day
        case week

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: return String(localized: "כל הזמנים")
            case .day: return String(localized: "ב-24 השעות האחרונות")
            case .week: return String(localized: "בשבוע האחרון")
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .any: return nil
            case .day: return 24 * 3600
            case .week: return 7 * 24 * 3600
            }
        }
    }

    var searchText = ""
    var categoryIds: Set<UUID> = []
    var unitCodes: Set<String> = []
    var recentWindow: RecentWindow = .any
    var showOutOfStock = true
    var sort: SortOrder = .alphabetical

    /// Number of active filters (search and sort excluded), for the filter badge.
    var activeFilterCount: Int {
        (categoryIds.isEmpty ? 0 : 1)
            + (unitCodes.isEmpty ? 0 : 1)
            + (recentWindow == .any ? 0 : 1)
            + (showOutOfStock ? 0 : 1)
    }

    var isFiltering: Bool {
        activeFilterCount > 0 || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    mutating func reset() {
        let sort = self.sort
        self = InventoryFilter()
        self.sort = sort
    }
}

enum InventoryQuery {
    private static let collation = Locale(identifier: "he_IL")

    /// Applies search, filters and sorting.
    ///
    /// Zero-stock policy: products that ran out stay in the inventory (with
    /// their history) and are listed after in-stock products, unless the
    /// volunteer hides them or sorts by quantity.
    static func apply(_ filter: InventoryFilter, to items: [InventoryItem], now: Date = Date()) -> [InventoryItem] {
        let needle = ProductNameNormalizer.key(filter.searchText)

        let filtered = items.filter { item in
            guard item.isActive else { return false }
            if !needle.isEmpty {
                let haystack = item.variant.isEmpty ? item.nameKey : item.nameKey + " " + ProductNameNormalizer.key(item.variant)
                if !haystack.contains(needle) { return false }
            }
            if !filter.categoryIds.isEmpty {
                guard let categoryId = item.categoryId, filter.categoryIds.contains(categoryId) else { return false }
            }
            if !filter.unitCodes.isEmpty, !filter.unitCodes.contains(item.unitCode) { return false }
            if let window = filter.recentWindow.interval, now.timeIntervalSince(item.updatedAt) > window { return false }
            if !filter.showOutOfStock, item.isOutOfStock { return false }
            return true
        }

        return filtered.sorted { lhs, rhs in
            switch filter.sort {
            case .quantityDescending:
                if lhs.quantity != rhs.quantity { return lhs.quantity > rhs.quantity }
                return alphabetical(lhs, rhs)
            case .quantityAscending:
                if lhs.quantity != rhs.quantity { return lhs.quantity < rhs.quantity }
                return alphabetical(lhs, rhs)
            case .alphabetical:
                if lhs.isOutOfStock != rhs.isOutOfStock { return !lhs.isOutOfStock }
                return alphabetical(lhs, rhs)
            case .recentlyUpdated:
                if lhs.isOutOfStock != rhs.isOutOfStock { return !lhs.isOutOfStock }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return alphabetical(lhs, rhs)
            }
        }
    }

    /// Products whose name matches what the volunteer is typing, best matches first.
    static func suggestions(for text: String, in items: [InventoryItem], limit: Int = 5) -> [InventoryItem] {
        let needle = ProductNameNormalizer.key(text)
        guard !needle.isEmpty else { return [] }
        return items
            .filter { $0.isActive && $0.nameKey.contains(needle) }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.nameKey.hasPrefix(needle)
                let rhsPrefix = rhs.nameKey.hasPrefix(needle)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return alphabetical(lhs, rhs)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The product that adding `name` in `unitCode` would increase, if any.
    static func existingProduct(named name: String, unitCode: String?, in items: [InventoryItem]) -> InventoryItem? {
        guard let unitCode else { return nil }
        let key = ProductNameNormalizer.key(name)
        guard !key.isEmpty else { return nil }
        return items.first { $0.isActive && $0.nameKey == key && $0.unitCode == unitCode && $0.variant.isEmpty }
    }

    /// Products with the same name but a different unit — they will NOT be
    /// combined, and the form says so.
    static func sameNameOtherUnits(named name: String, unitCode: String?, in items: [InventoryItem]) -> [InventoryItem] {
        let key = ProductNameNormalizer.key(name)
        guard !key.isEmpty else { return [] }
        return items.filter { $0.isActive && $0.nameKey == key && $0.unitCode != unitCode }
    }

    private static func alphabetical(_ lhs: InventoryItem, _ rhs: InventoryItem) -> Bool {
        let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: collation)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.unitCode < rhs.unitCode
    }
}

/// Header statistics. Quantities are only summed within compatible units:
/// count units as items, mass in kg, volume in liters.
struct InventoryTotals: Equatable, Sendable {
    var productCount = 0
    var inStockCount = 0
    var outOfStockCount = 0
    var itemCount: Decimal = 0
    var massKg: Decimal = 0
    var volumeLiters: Decimal = 0

    static func compute(items: [InventoryItem], units: [String: MeasurementUnit]) -> InventoryTotals {
        var totals = InventoryTotals()
        for item in items where item.isActive {
            totals.productCount += 1
            if item.isOutOfStock {
                totals.outOfStockCount += 1
            } else {
                totals.inStockCount += 1
            }
            guard let unit = units[item.unitCode] else { continue }
            switch unit.dimension {
            case .count: totals.itemCount += item.quantity
            case .mass: totals.massKg += item.quantity * unit.baseFactor / 1000
            case .volume: totals.volumeLiters += item.quantity * unit.baseFactor / 1000
            }
        }
        return totals
    }
}
