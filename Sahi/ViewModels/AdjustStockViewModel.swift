import Foundation
import Observation

/// State and rules for increasing, decreasing or counting a product's stock.
@MainActor
@Observable
final class AdjustStockViewModel {
    enum Mode: String, CaseIterable, Identifiable {
        case increase
        case decrease
        case set

        var id: String { rawValue }

        var title: String {
            switch self {
            case .increase: return String(localized: "הוספה")
            case .decrease: return String(localized: "הוצאה")
            case .set: return String(localized: "ספירת מלאי")
            }
        }

        var symbol: String {
            switch self {
            case .increase: return "plus.circle.fill"
            case .decrease: return "minus.circle.fill"
            case .set: return "equal.circle.fill"
            }
        }

        var reasons: [StockReason] {
            switch self {
            case .increase: return StockReason.forIncrease
            case .decrease: return StockReason.forDecrease
            case .set: return [.correction, .other]
            }
        }
    }

    enum Outcome: Equatable {
        case saved(String)
        case queued(String)
    }

    /// Change with `setMode(_:)`, which also resets dependent fields.
    private(set) var mode: Mode
    var quantityText = ""
    var reason: StockReason?
    var note = ""

    private(set) var isSaving = false
    private(set) var showValidation = false
    private(set) var serverError: AppError?

    let productId: UUID
    /// Stable per sheet so an accidental double submit is applied once.
    private(set) var requestId = UUID()

    @ObservationIgnored private let store: InventoryStore
    /// Stock version the volunteer saw when opening the sheet (for exact counts).
    @ObservationIgnored private var expectedStockVersion: Int?

    init(store: InventoryStore, productId: UUID, mode: Mode) {
        self.store = store
        self.productId = productId
        self.mode = mode
        self.expectedStockVersion = store.item(id: productId)?.stockVersion
        if mode == .set, let item = store.item(id: productId) {
            quantityText = QuantityFormatter.editableString(item.quantity)
        }
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        reason = nil
        showValidation = false
        serverError = nil
        if newMode == .set, let item {
            quantityText = QuantityFormatter.editableString(item.quantity)
            expectedStockVersion = item.stockVersion
        } else {
            quantityText = ""
        }
    }

    // MARK: - Derived state

    var item: InventoryItem? { store.item(id: productId) }
    var unit: MeasurementUnit? { item.map { store.unit(for: $0.unitCode) } }

    private var parsedQuantity: Result<Decimal, ValidationIssue> {
        ProductValidator.validateQuantity(quantityText, unit: unit, allowZero: mode == .set)
    }

    /// Stock after the change, if the input is valid.
    var resultingQuantity: Decimal? {
        guard let item, case .success(let value) = parsedQuantity else { return nil }
        switch mode {
        case .increase: return item.quantity + value
        case .decrease: return item.quantity - value
        case .set: return value
        }
    }

    var quantityIssue: ValidationIssue? {
        guard showValidation else { return nil }
        switch parsedQuantity {
        case .failure(let issue):
            return issue
        case .success:
            if mode == .decrease, let item, let result = resultingQuantity, result < 0 {
                return .insufficientStock(available: QuantityFormatter.string(item.quantity))
            }
            return nil
        }
    }

    var notesIssue: ValidationIssue? {
        showValidation ? ProductValidator.validateNotes(note) : nil
    }

    /// Non-nil when the change needs an explicit confirmation.
    var confirmationReason: StockChangeGuard.Reason? {
        guard let item, let result = resultingQuantity, result >= 0 else { return nil }
        return StockChangeGuard.confirmationReason(current: item.quantity, new: result)
    }

    /// Validates the form. Returns true when it can be submitted.
    func validate() -> Bool {
        showValidation = true
        return quantityIssue == nil && notesIssue == nil && item != nil
    }

    // MARK: - Submit

    func submit() async -> Outcome? {
        guard !isSaving, validate(), let item, let unit, case .success(let value) = parsedQuantity else { return nil }
        serverError = nil
        isSaving = true
        defer { isSaving = false }

        let storedReason = StockReason.encode(reason, note: note)
        let amount = QuantityFormatter.string(value)
        do {
            switch mode {
            case .increase, .decrease:
                let delta = mode == .increase ? value : -value
                let request = AdjustStockRequest(productId: item.id, delta: delta, reason: storedReason, requestId: requestId)
                let outcome = try await store.adjustStock(request)
                switch outcome {
                case .saved:
                    return .saved(mode == .increase
                        ? String(localized: "נוספו \(amount) \(unit.displayName) \(item.name)")
                        : String(localized: "הוצאו \(amount) \(unit.displayName) \(item.name)"))
                case .queued:
                    return .queued(String(localized: "אין חיבור — השינוי נשמר ויישלח אוטומטית"))
                }
            case .set:
                let request = SetStockRequest(
                    productId: item.id,
                    newQuantity: value,
                    expectedVersion: expectedStockVersion ?? item.stockVersion,
                    reason: storedReason,
                    requestId: requestId
                )
                let result = try await store.setStock(request)
                let previous = QuantityFormatter.string(result.previousQuantity ?? item.quantity)
                return .saved(String(localized: "הכמות של \(item.name) עודכנה מ-\(previous) ל-\(amount)"))
            }
        } catch {
            let appError = (error as? AppError) ?? AppError.fromGeneric(error)
            serverError = appError
            if appError == .versionConflict, let fresh = store.item(id: productId) {
                // Show the latest count and let the volunteer decide again.
                expectedStockVersion = fresh.stockVersion
                requestId = UUID()
            }
            return nil
        }
    }
}
