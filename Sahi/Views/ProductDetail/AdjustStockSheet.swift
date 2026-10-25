import SwiftUI

/// "עדכון כמות": add to, remove from, or count a product's stock.
struct AdjustStockSheet: View {
    typealias Mode = AdjustStockViewModel.Mode

    let productId: UUID
    let initialMode: Mode

    @Environment(InventoryStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: AdjustStockViewModel?
    @State private var pendingConfirmation: StockChangeGuard.Reason?
    @FocusState private var quantityFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel, let item = viewModel.item {
                    content(viewModel, item: item)
                } else if viewModel != nil {
                    ContentUnavailableView("המוצר לא נמצא", systemImage: "questionmark.folder")
                } else {
                    ProgressView()
                }
            }
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle(Text("עדכון כמות"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                        .disabled(viewModel?.isSaving ?? false)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("סיום") { quantityFocused = false }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(viewModel?.isSaving ?? false)
        .onAppear {
            if viewModel == nil {
                viewModel = AdjustStockViewModel(store: store, productId: productId, mode: initialMode)
                quantityFocused = initialMode != .set
            }
        }
    }

    private func content(_ viewModel: AdjustStockViewModel, item: InventoryItem) -> some View {
        @Bindable var viewModel = viewModel
        let unit = store.unit(for: item.unitCode)

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    CategoryIcon(category: store.category(for: item.categoryId))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Brand.navy)
                        Text("במלאי כעת: \(QuantityFormatter.withUnit(item.quantity, unit))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("סוג העדכון", selection: Binding(get: { viewModel.mode }, set: { viewModel.setMode($0) })) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    FormSectionTitle(title: viewModel.mode == .set ? "הכמות שנספרה" : "כמות", systemImage: "number")
                    QuantityField(
                        text: $viewModel.quantityText,
                        allowsFractions: unit.allowsFractions,
                        focus: $quantityFocused
                    )
                    FieldError(message: viewModel.quantityIssue?.message)
                    if let result = viewModel.resultingQuantity, result >= 0 {
                        HStack(spacing: 8) {
                            Text(QuantityFormatter.string(item.quantity))
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.forward")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(QuantityFormatter.withUnit(result, unit))
                                .fontWeight(.bold)
                                .foregroundStyle(Brand.blue)
                        }
                        .font(.headline)
                        .monospacedDigit()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("אחרי העדכון: \(QuantityFormatter.withUnit(result, unit))"))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    FormSectionTitle(title: "סיבה (לא חובה)", systemImage: "text.bubble")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(viewModel.mode.reasons) { reason in
                            SelectableChip(title: reason.title, isSelected: viewModel.reason == reason) {
                                viewModel.reason = viewModel.reason == reason ? nil : reason
                            }
                        }
                    }
                    TextField("הערה", text: $viewModel.note, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(14)
                        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.cardBorder))
                    FieldError(message: viewModel.notesIssue?.message)
                }

                if viewModel.mode == .set {
                    Text("ספירת מלאי קובעת את הכמות המדויקת. אם מתנדב/ת אחר/ת עדכנ/ה את המוצר בינתיים, תתבקשו לבדוק שוב — כך שינויים לא נדרסים.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !store.isOnline {
                    StatusBanner(kind: .offline, title: String(localized: "אין חיבור"),
                                 message: String(localized: "השינוי יישמר וישלח אוטומטית כשהחיבור יחזור."))
                }

                if let error = viewModel.serverError {
                    StatusBanner(kind: .warning, title: String(localized: "השמירה נכשלה"), message: error.localizedDescription)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    quantityFocused = false
                    guard viewModel.validate() else { return }
                    if let reason = viewModel.confirmationReason {
                        pendingConfirmation = reason
                    } else {
                        save(viewModel)
                    }
                } label: {
                    ProgressLabel(title: "שמירה", systemImage: viewModel.mode.symbol, isLoading: viewModel.isSaving)
                }
                .buttonStyle(.sahiPrimary(tint: viewModel.mode == .decrease ? Brand.danger : Brand.blue))
                .disabled(viewModel.isSaving || (viewModel.mode == .set && !store.isOnline))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
        .confirmationDialog(
            Text("שינוי משמעותי במלאי"),
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { _ in
            Button("כן, לעדכן", role: viewModel.mode == .increase ? nil : .destructive) {
                save(viewModel)
            }
            Button("ביטול", role: .cancel) {}
        } message: { reason in
            Text(reason.message)
        }
    }

    private func save(_ viewModel: AdjustStockViewModel) {
        Task {
            guard let outcome = await viewModel.submit() else { return }
            switch outcome {
            case .saved(let message): toasts.show(message, style: .success)
            case .queued(let message): toasts.show(message, style: .warning)
            }
            dismiss()
        }
    }
}
