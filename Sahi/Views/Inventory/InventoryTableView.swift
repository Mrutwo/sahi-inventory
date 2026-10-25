import SwiftUI

/// Table presentation of the inventory.
///
/// Wide layouts (large phones in landscape, iPad, smaller text) show the five
/// columns separately: שם המוצר · כמות · יחידה · קטגוריה · עודכן לאחרונה.
/// On narrow screens related columns are merged so nothing is clipped and
/// nothing scrolls sideways: [name + category] · [quantity + unit] · [updated].
struct InventoryTableView: View {
    @Environment(InventoryStore.self) private var store
    let items: [InventoryItem]
    let isWide: Bool
    let pendingDelta: @MainActor (InventoryItem) -> Decimal

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                NavigationLink(value: item.id) {
                    row(item)
                        .background(index.isMultiple(of: 2) ? Color.clear : Brand.blueSoft.opacity(0.5))
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Divider().overlay(Brand.cardBorder)
                }
            }
        }
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Brand.cardBorder, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            if isWide {
                headerCell("שם המוצר").frame(maxWidth: .infinity, alignment: .leading)
                headerCell("כמות").frame(width: 70, alignment: .trailing)
                headerCell("יחידה").frame(width: 72, alignment: .leading)
                headerCell("קטגוריה").frame(width: 120, alignment: .leading)
                headerCell("עודכן לאחרונה").frame(width: 110, alignment: .leading)
            } else {
                headerCell("שם המוצר").frame(maxWidth: .infinity, alignment: .leading)
                headerCell("כמות").frame(width: 84, alignment: .trailing)
                headerCell("עודכן").frame(width: 76, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.blueMid.opacity(0.45))
        .accessibilityHidden(true)
    }

    private func headerCell(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Brand.navy)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func row(_ item: InventoryItem) -> some View {
        let unit = store.unit(for: item.unitCode)
        let category = store.category(for: item.categoryId)
        let pending = pendingDelta(item)

        HStack(spacing: 8) {
            if isWide {
                nameCell(item, pending: pending)
                    .frame(maxWidth: .infinity, alignment: .leading)
                quantityText(item)
                    .frame(width: 70, alignment: .trailing)
                Text(unit.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Text(category?.displayName ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)
                Text(item.updatedAt.sahiRelativeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 110, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    nameCell(item, pending: pending)
                    if let category {
                        Text(category.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    quantityText(item)
                    Text(unit.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 84, alignment: .trailing)
                Text(item.updatedAt.sahiRelativeDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 76, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [
            item.name,
            "\(QuantityFormatter.string(item.quantity)) \(unit.displayName)",
            category?.displayName ?? "",
            item.isOutOfStock ? String(localized: "אזל מהמלאי") : "",
        ].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
    }

    private func nameCell(_ item: InventoryItem, pending: Decimal) -> some View {
        HStack(spacing: 6) {
            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.navy)
                .lineLimit(2)
            if item.isOutOfStock {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.goldText)
            }
            if pending != 0 {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(Brand.blue)
            }
        }
    }

    private func quantityText(_ item: InventoryItem) -> some View {
        Text(QuantityFormatter.string(item.quantity))
            .font(.headline)
            .monospacedDigit()
            .foregroundStyle(item.isOutOfStock ? Color.secondary : Brand.blue)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
