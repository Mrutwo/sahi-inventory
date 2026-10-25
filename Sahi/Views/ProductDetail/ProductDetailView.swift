import SwiftUI

/// Product details: current stock, quick actions and recent history.
struct ProductDetailView: View {
    let productId: UUID

    @Environment(InventoryStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var history: [ActivityEntry] = []
    @State private var historyError: AppError?
    @State private var isLoadingHistory = false
    @State private var adjusting: AdjustTarget?
    @State private var isEditing = false
    @State private var isConfirmingArchive = false
    @State private var isArchiving = false

    var body: some View {
        Group {
            if let item = store.item(id: productId) {
                details(item)
            } else {
                ContentUnavailableView {
                    Label("המוצר הוסר מהמלאי", systemImage: "archivebox")
                } description: {
                    Text("ייתכן שמתנדב/ת אחר/ת הסיר/ה את המוצר. ההיסטוריה שלו נשמרה.")
                } actions: {
                    Button("חזרה למלאי") { dismiss() }
                        .buttonStyle(.sahiSecondary)
                        .frame(maxWidth: 220)
                }
            }
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.changeToken) {
            await loadHistory()
        }
        .sheet(item: $adjusting) { target in
            AdjustStockSheet(productId: target.productId, initialMode: target.mode)
        }
        .sheet(isPresented: $isEditing) {
            EditProductSheet(productId: productId)
        }
    }

    private func details(_ item: InventoryItem) -> some View {
        let unit = store.unit(for: item.unitCode)
        let category = store.category(for: item.categoryId)
        let pending = store.pending.pendingDelta(for: item)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Summary card
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        CategoryIcon(category: category, size: 54)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Brand.navy)
                                .accessibilityAddTraits(.isHeader)
                            if !item.variant.isEmpty {
                                Text(item.variant)
                                    .foregroundStyle(.secondary)
                            }
                            Text(category?.displayName ?? String(localized: "אחר"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(QuantityFormatter.string(item.quantity))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(item.isOutOfStock ? Color.secondary : Brand.blue)
                            .contentTransition(.numericText())
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(unit.displayName)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("במלאי: \(QuantityFormatter.withUnit(item.quantity, unit))"))

                    HStack(spacing: 8) {
                        if item.isOutOfStock {
                            TagView(text: String(localized: "אזל מהמלאי"), systemImage: "exclamationmark.circle",
                                    tint: Brand.goldText, background: Brand.gold.opacity(0.18))
                        }
                        if pending != 0 {
                            TagView(text: String(localized: "\(QuantityFormatter.signed(pending)) ממתין לסנכרון"),
                                    systemImage: "icloud.and.arrow.up")
                        }
                    }

                    Label {
                        if let name = item.updatedByName {
                            Text("עודכן \(item.updatedAt.sahiRelativeDescription) על ידי \(name)")
                        } else {
                            Text("עודכן \(item.updatedAt.sahiRelativeDescription)")
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let notes = item.notes, !notes.isEmpty {
                        Label(notes, systemImage: "note.text")
                            .font(.subheadline)
                            .foregroundStyle(Brand.navy)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Brand.blueSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .cardStyle(padding: 18)

                // Quick actions
                HStack(spacing: 10) {
                    Button {
                        adjusting = AdjustTarget(productId: item.id, mode: .increase)
                    } label: {
                        Label("הוספה", systemImage: "plus")
                    }
                    .buttonStyle(.sahiPrimary)

                    Button {
                        adjusting = AdjustTarget(productId: item.id, mode: .decrease)
                    } label: {
                        Label("הוצאה", systemImage: "minus")
                    }
                    .buttonStyle(.sahiSecondary)
                    .disabled(item.isOutOfStock)
                }

                Button {
                    adjusting = AdjustTarget(productId: item.id, mode: .set)
                } label: {
                    Label("ספירת מלאי – עדכון כמות מדויקת", systemImage: "equal.circle")
                }
                .buttonStyle(.sahiSecondary)

                historySection

                if session.isAdmin {
                    archiveSection(item)
                } else {
                    Text("הסרת מוצר מהמלאי מותרת למנהלים בלבד.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
        .refreshable {
            await store.refresh()
            await loadHistory()
        }
        .navigationTitle(Text(item.name))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("עריכה") { isEditing = true }
                    .disabled(!store.isOnline)
            }
        }
        .confirmationDialog(
            Text("מחיקת מוצר"),
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible
        ) {
            Button("הסרה מהמלאי", role: .destructive) {
                archive(item)
            }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("\(item.name) יוסר מהמלאי הפעיל. הכמות הנוכחית (\(QuantityFormatter.withUnit(item.quantity, unit))) תירשם כהוצאה, וכל ההיסטוריה תישמר. מנהלים יכולים להחזיר את המוצר.")
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("היסטוריית שינויים")
                    .font(.headline)
                    .foregroundStyle(Brand.navy)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isLoadingHistory {
                    ProgressView()
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if let historyError, history.isEmpty {
                    Text(historyError.localizedDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if history.isEmpty && !isLoadingHistory {
                    Text("אין עדיין שינויים להצגה.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(history) { entry in
                    ActivityRow(entry: entry, includeProduct: false)
                    if entry.id != history.last?.id {
                        Divider()
                    }
                }
            }
            .cardStyle(padding: 14)
        }
    }

    private func archiveSection(_ item: InventoryItem) -> some View {
        Button(role: .destructive) {
            isConfirmingArchive = true
        } label: {
            if isArchiving {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                Label("מחיקת מוצר", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
        }
        .font(.headline)
        .foregroundStyle(Brand.danger)
        .background(Brand.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(isArchiving || !store.isOnline)
        .padding(.top, 8)
    }

    private func loadHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            history = try await store.fetchActivity(productId: productId, limit: 50)
            historyError = nil
        } catch is CancellationError {
            return
        } catch {
            historyError = (error as? AppError) ?? AppError.fromGeneric(error)
        }
    }

    private func archive(_ item: InventoryItem) {
        isArchiving = true
        Task {
            defer { isArchiving = false }
            do {
                try await store.archiveProduct(id: item.id, reason: nil)
                toasts.show(String(localized: "\(item.name) הוסר מהמלאי"), style: .success)
                dismiss()
            } catch {
                let appError = (error as? AppError) ?? AppError.fromGeneric(error)
                toasts.show(appError.localizedDescription, style: .error)
            }
        }
    }
}
