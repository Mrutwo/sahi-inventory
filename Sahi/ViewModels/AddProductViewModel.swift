import Foundation
import Observation

/// State and rules for the "הוספת מוצר" form.
@MainActor
@Observable
final class AddProductViewModel {
    enum Outcome: Equatable {
        case saved(String)
        case queued(String)
    }

    var name = ""
    var quantityText = ""
    var unitCode: String?
    var categoryId: UUID?
    var notes = ""

    private(set) var isSaving = false
    /// Validation messages appear only after the first save attempt.
    private(set) var showValidation = false
    private(set) var serverError: AppError?

    /// One id per form: a double tap or a retry after a timeout is applied once.
    let requestId = UUID()

    @ObservationIgnored private let store: InventoryStore

    init(store: InventoryStore, prefillName: String = "") {
        self.store = store
        self.name = prefillName
    }

    // MARK: - Derived state

    var selectedUnit: MeasurementUnit? { unitCode.map { store.unit(for: $0) } }

    var nameIssue: ValidationIssue? {
        showValidation ? ProductValidator.validateName(name) : nil
    }

    var quantityIssue: ValidationIssue? {
        guard showValidation else { return nil }
        if case .failure(let issue) = ProductValidator.validateQuantity(quantityText, unit: selectedUnit) {
            return issue
        }
        return nil
    }

    var unitIssue: ValidationIssue? {
        showValidation && unitCode == nil ? .unitMissing : nil
    }

    var notesIssue: ValidationIssue? {
        showValidation ? ProductValidator.validateNotes(notes) : nil
    }

    /// The product this form will increase instead of creating a duplicate row.
    var existingProduct: InventoryItem? {
        InventoryQuery.existingProduct(named: name, unitCode: unitCode, in: store.items)
    }

    /// Same name, other units — shown so volunteers know these stay separate.
    var sameNameOtherUnits: [InventoryItem] {
        InventoryQuery.sameNameOtherUnits(named: name, unitCode: unitCode, in: store.items)
    }

    var suggestions: [InventoryItem] {
        let key = ProductNameNormalizer.key(name)
        return InventoryQuery.suggestions(for: name, in: store.items)
            .filter { !($0.nameKey == key && $0.unitCode == unitCode) }
    }

    /// Stock after saving, for the "25 → 35" preview.
    var resultingQuantity: Decimal? {
        guard let existing = existingProduct,
              case .success(let quantity) = ProductValidator.validateQuantity(quantityText, unit: selectedUnit)
        else { return nil }
        return existing.quantity + quantity
    }

    var hasChanges: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty || !quantityText.isEmpty || !notes.isEmpty
    }

    // MARK: - Actions

    func selectSuggestion(_ item: InventoryItem) {
        name = item.name
        unitCode = item.unitCode
        categoryId = item.categoryId
    }

    func selectUnit(_ code: String) {
        unitCode = code
        // A count cannot be fractional; drop the fraction rather than fail later.
        if let unit = selectedUnit, !unit.allowsFractions,
           let parsed = QuantityParser.parse(quantityText), parsed.fractionDigits > 0 {
            quantityText = QuantityFormatter.editableString(parsed.value.sahiRounded(scale: 0, mode: .down))
        }
        if categoryId == nil, let match = sameNameOtherUnits.first {
            categoryId = match.categoryId
        }
    }

    /// Validates and builds the request; nil if the form is invalid.
    func makeRequest() -> AddStockRequest? {
        showValidation = true
        guard ProductValidator.validateName(name) == nil,
              ProductValidator.validateNotes(notes) == nil,
              let unitCode,
              case .success(let quantity) = ProductValidator.validateQuantity(quantityText, unit: selectedUnit)
        else { return nil }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return AddStockRequest(
            name: ProductNameNormalizer.displayName(name),
            unitCode: unitCode,
            quantity: quantity,
            categoryId: existingProduct?.categoryId ?? categoryId,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            requestId: requestId
        )
    }

    func submit() async -> Outcome? {
        guard !isSaving else { return nil }
        serverError = nil
        guard let request = makeRequest() else { return nil }
        let unit = store.unit(for: request.unitCode)
        let wasExisting = existingProduct != nil

        isSaving = true
        defer { isSaving = false }
        do {
            let outcome = try await store.addStock(request)
            switch outcome {
            case .saved(let result):
                let amount = QuantityFormatter.string(request.quantity)
                if wasExisting, let newQuantity = result.newQuantity {
                    return .saved(String(localized: "נוספו \(amount) \(unit.displayName) \(request.name) · סה״כ \(QuantityFormatter.string(newQuantity))"))
                }
                return .saved(String(localized: "נוספו \(amount) \(unit.displayName) \(request.name)"))
            case .queued:
                return .queued(String(localized: "אין חיבור — השינוי נשמר ויישלח אוטומטית"))
            }
        } catch {
            serverError = (error as? AppError) ?? AppError.fromGeneric(error)
            return nil
        }
    }
}
