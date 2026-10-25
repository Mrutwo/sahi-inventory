import SwiftUI

/// Top of the inventory: branding, title, totals and the main "add" action.
struct InventoryHeaderView: View {
    let totals: InventoryTotals
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SahiLogoView(size: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "סח״י")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.blue)
                    Text("מלאי מוצרים")
                        .font(.title.weight(.bold))
                        .foregroundStyle(Brand.navy)
                        .accessibilityAddTraits(.isHeader)
                    Text("מלאי משותף לכל המתנדבים")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { stats }
                VStack(spacing: 10) { stats }
            }

            Button(action: onAdd) {
                Label("הוספת מוצר", systemImage: "plus")
            }
            .buttonStyle(.sahiPrimary)
            .accessibilityHint(Text("פותח טופס להוספת מוצר או כמות למלאי"))
        }
        .cardStyle(padding: 18)
    }

    @ViewBuilder
    private var stats: some View {
        StatTile(
            value: "\(totals.productCount)",
            label: String(localized: "סוגי מוצרים"),
            systemImage: "square.stack.3d.up.fill"
        )
        StatTile(
            value: QuantityFormatter.string(totals.itemCount),
            label: String(localized: "פריטים במלאי"),
            systemImage: "shippingbox.fill"
        )
        if totals.massKg > 0 {
            StatTile(
                value: QuantityFormatter.string(totals.massKg),
                label: String(localized: "ק\"ג"),
                systemImage: "scalemass.fill"
            )
        }
        if totals.volumeLiters > 0 {
            StatTile(
                value: QuantityFormatter.string(totals.volumeLiters),
                label: String(localized: "ליטרים"),
                systemImage: "drop.fill"
            )
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(Brand.blue)
                .accessibilityHidden(true)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Brand.navy)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.blueSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
