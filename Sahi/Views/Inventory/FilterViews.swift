import SwiftUI

/// Horizontal category chips above the list (one tap to filter).
struct CategoryFilterBar: View {
    let categories: [ProductCategory]
    @Binding var selected: Set<UUID>

    var body: some View {
        if !categories.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: String(localized: "הכל"), systemImage: "square.grid.2x2", isSelected: selected.isEmpty) {
                        selected = []
                    }
                    ForEach(categories) { category in
                        chip(title: category.displayName, systemImage: category.symbolName,
                             isSelected: selected.contains(category.id)) {
                            if selected.contains(category.id) {
                                selected.remove(category.id)
                            } else {
                                selected.insert(category.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityLabel(Text("סינון לפי קטגוריה"))
        }
    }

    private func chip(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .foregroundStyle(isSelected ? Color.white : Brand.navy)
                .background(Capsule().fill(isSelected ? Brand.blue : Brand.card))
                .overlay(Capsule().strokeBorder(isSelected ? Brand.blue : Brand.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Full filter & sort sheet.
struct FilterSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section("מיון") {
                    Picker("מיון", selection: $store.filter.sort) {
                        ForEach(InventoryFilter.SortOrder.allCases) { order in
                            Label(order.title, systemImage: order.symbol).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("עודכנו לאחרונה") {
                    Picker("עודכנו לאחרונה", selection: $store.filter.recentWindow) {
                        ForEach(InventoryFilter.RecentWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("יחידת מידה") {
                    ForEach(store.activeUnits) { unit in
                        Toggle(unit.displayName, isOn: Binding(
                            get: { store.filter.unitCodes.contains(unit.code) },
                            set: { isOn in
                                if isOn {
                                    store.filter.unitCodes.insert(unit.code)
                                } else {
                                    store.filter.unitCodes.remove(unit.code)
                                }
                            }
                        ))
                    }
                }

                Section("קטגוריה") {
                    ForEach(store.activeCategories) { category in
                        Toggle(isOn: Binding(
                            get: { store.filter.categoryIds.contains(category.id) },
                            set: { isOn in
                                if isOn {
                                    store.filter.categoryIds.insert(category.id)
                                } else {
                                    store.filter.categoryIds.remove(category.id)
                                }
                            }
                        )) {
                            Label(category.displayName, systemImage: category.symbolName)
                        }
                    }
                }

                Section {
                    Toggle("הצגת מוצרים שאזלו", isOn: $store.filter.showOutOfStock)
                } footer: {
                    Text("מוצרים שהכמות שלהם הגיעה לאפס נשארים במלאי עם ההיסטוריה שלהם ומוצגים בסוף הרשימה.")
                }

                if store.filter.activeFilterCount > 0 {
                    Section {
                        Button("ניקוי כל המסננים", role: .destructive) {
                            store.filter.reset()
                        }
                    }
                }
            }
            .navigationTitle(Text("סינון ומיון"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סיום") { dismiss() }
                }
            }
        }
    }
}
