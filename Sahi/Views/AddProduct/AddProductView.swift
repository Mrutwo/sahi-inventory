import SwiftUI

/// "הוספת מוצר" — the main task, designed for as few taps as possible:
/// name (with suggestions) → quantity → unit → save.
struct AddProductView: View {
    private enum Field: Hashable {
        case name
        case notes
    }

    @Environment(InventoryStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: AddProductViewModel?
    @FocusState private var focusedField: Field?
    @FocusState private var quantityFocused: Bool
    @State private var showsSuggestions = true

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    form(viewModel)
                } else {
                    ProgressView()
                }
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle(Text("הוספת מוצר"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                        .disabled(viewModel?.isSaving ?? false)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("סיום") {
                        focusedField = nil
                        quantityFocused = false
                    }
                }
            }
        }
        .interactiveDismissDisabled(viewModel?.isSaving ?? false)
        .onAppear {
            if viewModel == nil {
                viewModel = AddProductViewModel(store: store)
                focusedField = .name
            }
        }
    }

    // MARK: - Form

    private func form(_ viewModel: AddProductViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                nameSection(viewModel)
                quantitySection(viewModel)
                unitSection(viewModel)
                categorySection(viewModel)
                notesSection(viewModel)
                if let error = viewModel.serverError {
                    StatusBanner(kind: .warning, title: String(localized: "השמירה נכשלה"), message: error.localizedDescription)
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: viewModel.showValidation)
            .animation(.easeInOut(duration: 0.2), value: viewModel.existingProduct?.id)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            saveBar(viewModel)
        }
    }

    private func nameSection(_ viewModel: AddProductViewModel) -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            FormSectionTitle(title: "שם המוצר", systemImage: "tag")
            TextField("למשל: אורז, שמן, טונה", text: $viewModel.name)
                .font(.title3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .name)
                .onSubmit { quantityFocused = true }
                .onChange(of: viewModel.name) { _, _ in showsSuggestions = true }
                .padding(14)
                .frame(minHeight: 52)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(viewModel.nameIssue == nil ? Brand.cardBorder : Brand.danger, lineWidth: 1)
                )
            FieldError(message: viewModel.nameIssue?.message)

            if showsSuggestions, focusedField == .name, !viewModel.suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(viewModel.suggestions) { item in
                        Button {
                            viewModel.selectSuggestion(item)
                            showsSuggestions = false
                            quantityFocused = true
                        } label: {
                            HStack {
                                CategoryIcon(category: store.category(for: item.categoryId), size: 32)
                                Text(item.name)
                                    .foregroundStyle(Brand.navy)
                                Spacer()
                                Text(QuantityFormatter.withUnit(item.quantity, store.unit(for: item.unitCode)))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("בחירת מוצר קיים"))
                        if item.id != viewModel.suggestions.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.cardBorder))
            }

            if let existing = viewModel.existingProduct {
                let unit = store.unit(for: existing.unitCode)
                StatusBanner(
                    kind: .info,
                    title: String(localized: "המוצר כבר קיים במלאי: \(QuantityFormatter.withUnit(existing.quantity, unit))"),
                    message: viewModel.resultingQuantity.map {
                        String(localized: "הכמות תתווסף למלאי הקיים ← \(QuantityFormatter.withUnit($0, unit))")
                    } ?? String(localized: "הכמות תתווסף למלאי הקיים ולא תיווצר שורה כפולה.")
                )
            } else if let other = viewModel.sameNameOtherUnits.first, viewModel.unitCode != nil {
                StatusBanner(
                    kind: .warning,
                    title: String(localized: "\(other.name) קיים במלאי ב\(store.unit(for: other.unitCode).displayName)"),
                    message: String(localized: "יחידות מידה שונות אינן מתאחדות — יישמר כמוצר נפרד.")
                )
            }
        }
    }

    private func quantitySection(_ viewModel: AddProductViewModel) -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            FormSectionTitle(title: "כמות", systemImage: "number")
            QuantityField(
                text: $viewModel.quantityText,
                allowsFractions: viewModel.selectedUnit?.allowsFractions ?? true,
                focus: $quantityFocused
            )
            FieldError(message: viewModel.quantityIssue?.message)
        }
    }

    private func unitSection(_ viewModel: AddProductViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FormSectionTitle(title: "יחידת מידה", systemImage: "scalemass")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(store.activeUnits) { unit in
                    SelectableChip(title: unit.displayName, isSelected: viewModel.unitCode == unit.code) {
                        viewModel.selectUnit(unit.code)
                    }
                }
            }
            FieldError(message: viewModel.unitIssue?.message)
        }
    }

    @ViewBuilder
    private func categorySection(_ viewModel: AddProductViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FormSectionTitle(title: "קטגוריה", systemImage: "square.grid.2x2")
            if let existing = viewModel.existingProduct {
                HStack(spacing: 10) {
                    CategoryIcon(category: store.category(for: existing.categoryId), size: 32)
                    Text(store.category(for: existing.categoryId)?.displayName ?? String(localized: "אחר"))
                        .foregroundStyle(Brand.navy)
                    Spacer()
                    Text("לפי המוצר הקיים")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .cardStyle(padding: 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(store.activeCategories) { category in
                        SelectableChip(
                            title: category.displayName,
                            systemImage: category.symbolName,
                            isSelected: viewModel.categoryId == category.id
                        ) {
                            viewModel.categoryId = viewModel.categoryId == category.id ? nil : category.id
                        }
                    }
                }
                Text("אם לא תיבחר קטגוריה, המוצר יישמר תחת \"אחר\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func notesSection(_ viewModel: AddProductViewModel) -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            FormSectionTitle(title: "הערות (לא חובה)", systemImage: "text.alignright")
            TextField("למשל: תרומה מהסופר השכונתי", text: $viewModel.notes, axis: .vertical)
                .lineLimit(2...5)
                .focused($focusedField, equals: .notes)
                .padding(14)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.cardBorder))
            FieldError(message: viewModel.notesIssue?.message)
        }
    }

    private func saveBar(_ viewModel: AddProductViewModel) -> some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                focusedField = nil
                quantityFocused = false
                Task {
                    guard let outcome = await viewModel.submit() else { return }
                    switch outcome {
                    case .saved(let message):
                        toasts.show(message, style: .success)
                    case .queued(let message):
                        toasts.show(message, style: .warning)
                    }
                    dismiss()
                }
            } label: {
                ProgressLabel(
                    title: viewModel.existingProduct == nil ? "שמירה" : "הוספה למלאי הקיים",
                    systemImage: "checkmark",
                    isLoading: viewModel.isSaving
                )
            }
            .buttonStyle(.sahiPrimary)
            .disabled(viewModel.isSaving)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}
