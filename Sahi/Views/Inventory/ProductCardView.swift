import SwiftUI

/// One product in the inventory list, readable at a glance:
/// category icon · name and category · big quantity with its unit.
struct ProductCardView: View {
    @Environment(InventoryStore.self) private var store
    let item: InventoryItem
    let pendingDelta: Decimal

    var body: some View {
        let unit = store.unit(for: item.unitCode)
        let category = store.category(for: item.categoryId)

        HStack(alignment: .center, spacing: 14) {
            CategoryIcon(category: category)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(Brand.navy)
                    .lineLimit(2)
                if !item.variant.isEmpty {
                    Text(item.variant)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let category {
                        Text(category.displayName)
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                    }
                    Text(item.updatedAt.sahiRelativeDescription)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                tags
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(QuantityFormatter.string(item.quantity))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(item.isOutOfStock ? Color.secondary : Brand.blue)
                    .contentTransition(.numericText())
                Text(unit.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .cardStyle(padding: 14)
        .contentShape(Rectangle())
        .animation(.snappy, value: item.quantity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(unit: unit, category: category))
        .accessibilityHint(Text("פתיחת פרטי המוצר"))
    }

    @ViewBuilder
    private var tags: some View {
        if item.isOutOfStock || pendingDelta != 0 {
            HStack(spacing: 6) {
                if item.isOutOfStock {
                    TagView(text: String(localized: "אזל מהמלאי"), systemImage: "exclamationmark.circle",
                            tint: Brand.goldText, background: Brand.gold.opacity(0.18))
                }
                if pendingDelta != 0 {
                    TagView(text: String(localized: "\(QuantityFormatter.signed(pendingDelta)) ממתין"),
                            systemImage: "icloud.and.arrow.up")
                }
            }
            .padding(.top, 2)
        }
    }

    private func accessibilityText(unit: MeasurementUnit, category: ProductCategory?) -> Text {
        var parts = [item.name, "\(QuantityFormatter.string(item.quantity)) \(unit.displayName)"]
        if let category { parts.append(category.displayName) }
        if item.isOutOfStock { parts.append(String(localized: "אזל מהמלאי")) }
        parts.append(String(localized: "עודכן \(item.updatedAt.sahiRelativeDescription)"))
        return Text(parts.joined(separator: ", "))
    }
}
