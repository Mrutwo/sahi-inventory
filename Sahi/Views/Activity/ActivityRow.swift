import SwiftUI

/// One entry of the stock history.
struct ActivityRow: View {
    @Environment(InventoryStore.self) private var store
    let entry: ActivityEntry
    var includeProduct = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(ActivityDescriber.sentence(for: entry, units: store.unitsByCode, includeProduct: includeProduct))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.navy)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(ActivityDescriber.detailLines(for: entry), id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let reason = StockReason.display(entry.reason) {
                    Label(reason, systemImage: "text.bubble")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    if let actor = entry.actorName, !actor.isEmpty {
                        Label(actor, systemImage: "person.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    Text(entry.createdAt.sahiDateTime)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.quantityDelta != 0 {
                Text(QuantityFormatter.signed(entry.quantityDelta))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(entry.quantityDelta > 0 ? Brand.green : Brand.danger)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch entry.kind {
        case .create: return "sparkles"
        case .increase: return "plus"
        case .decrease: return "minus"
        case .set: return "equal"
        case .edit: return "pencil"
        case .unitChange: return "arrow.left.arrow.right"
        case .archive: return "archivebox"
        case .restore: return "arrow.uturn.backward"
        case .unknown: return "circle"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .create, .increase, .restore: return Brand.green
        case .decrease, .archive: return Brand.danger
        case .set, .unitChange: return Brand.goldText
        case .edit, .unknown: return Brand.blue
        }
    }
}
