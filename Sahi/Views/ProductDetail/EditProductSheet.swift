import SwiftUI

/// Edit a product's name, category, unit (only where safe) and notes.
struct EditProductSheet: View {
    let productId: UUID

    @Environment(InventoryStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var categoryId: UUID?
    @State private var unitCode = ""
    @State private var notes = ""
    @State private var expectedVersion: Int?
    @State private var showValidation = false
    @State private var isSaving = false
    @State private var serverError: AppError?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if let item = store.item(id: productId) {
                    form(item)
                } else {
                    ContentUnavailableView("המוצר לא נמצא", systemImage: "questionmark.folder")
                }
            }
            .navigationTitle(Text("עריכת מוצר"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("שמירה") { save() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear(perform: loadValues)
    }

    private var nameIssue: ValidationIssue? {
        showValidation ? ProductValidator.validateName(name) : nil
    }

    private var notesIssue: ValidationIssue? {
        showValidation ? ProductValidator.validateNotes(notes) : nil
    }

    private func form(_ item: InventoryItem) -> some View {
        let currentUnit = store.unit(for: item.unitCode)

        return Form {
            Section {
                TextField("שם המוצר", text: $name)
                    .font(.body.weight(.semibold))
                    .frame(minHeight: 44)
                if let nameIssue {
                    FieldError(message: nameIssue.message)
                }
            } header: {
                Text("שם המוצר")
            }

            Section {
                Picker("קטגוריה", selection: $categoryId) {
                    ForEach(store.activeCategories) { category in
                        Label(category.displayName, systemImage: category.symbolName)
                            .tag(Optional(category.id))
                    }
                }
            } header: {
                Text("קטגוריה")
            }

            Section {
                Picker("יחידת מידה", selection: $unitCode) {
                    ForEach(store.activeUnits) { unit in
                        Text(unit.displayName)
                            .tag(unit.code)
                            .selectionDisabled(!isUnitAllowed(unit, for: item, current: currentUnit))
                    }
                }
                if unitCode != item.unitCode {
                    let newUnit = store.unit(for: unitCode)
                    if item.quantity > 0, currentUnit.canConvert(to: newUnit) {
                        Text("הכמות תומר: \(QuantityFormatter.withUnit(item.quantity, currentUnit)) ← \(QuantityFormatter.withUnit(item.quantity * currentUnit.baseFactor / newUnit.baseFactor, newUnit))")
                            .font(.footnote)
                            .foregroundStyle(Brand.blue)
                    }
                }
            } header: {
                Text("יחידת מידה")
            } footer: {
                Text(item.quantity > 0
                     ? "כשיש מלאי אפשר לעבור רק בין יחידות תואמות (ק\"ג ↔ גרם). כדי לעבור ליחידה אחרת יש לאפס קודם את המלאי."
                     : "המלאי ריק, לכן אפשר לבחור כל יחידה.")
            }

            Section {
                TextField("הערות", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                if let notesIssue {
                    FieldError(message: notesIssue.message)
                }
            } header: {
                Text("הערות")
            }

            if let serverError {
                Section {
                    Label(serverError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.danger)
                }
            }
        }
    }

    private func isUnitAllowed(_ unit: MeasurementUnit, for item: InventoryItem, current: MeasurementUnit) -> Bool {
        item.quantity == 0 || current.canConvert(to: unit)
    }

    private func loadValues() {
        guard !loaded, let item = store.item(id: productId) else { return }
        loaded = true
        name = item.name
        categoryId = item.categoryId
        unitCode = item.unitCode
        notes = item.notes ?? ""
        expectedVersion = item.productVersion
    }

    private func save() {
        showValidation = true
        guard let item = store.item(id: productId),
              ProductValidator.validateName(name) == nil,
              ProductValidator.validateNotes(notes) == nil
        else { return }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = UpdateProductRequest(
            productId: item.id,
            expectedVersion: expectedVersion ?? item.productVersion,
            name: ProductNameNormalizer.displayName(name),
            categoryId: categoryId,
            unitCode: unitCode,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )
        isSaving = true
        serverError = nil
        Task {
            defer { isSaving = false }
            do {
                try await store.updateProduct(request)
                toasts.show(String(localized: "פרטי המוצר עודכנו"), style: .success)
                dismiss()
            } catch {
                let appError = (error as? AppError) ?? AppError.fromGeneric(error)
                serverError = appError
                if appError == .versionConflict {
                    // The store refreshed; base the next save on the latest version.
                    expectedVersion = store.item(id: productId)?.productVersion
                }
            }
        }
    }
}
