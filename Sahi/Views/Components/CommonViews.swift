import SwiftUI

/// Round category icon used in rows, chips and headers.
struct CategoryIcon: View {
    let category: ProductCategory?
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: category?.symbolName ?? "shippingbox")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Brand.blue)
            .frame(width: size, height: size)
            .background(Brand.blueSoft, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Inline validation message under a field.
struct FieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.danger)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Section title inside forms.
struct FormSectionTitle: View {
    let title: LocalizedStringKey
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Brand.blue)
            }
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A selectable pill (units, categories, filters). At least 44 pt tall.
struct SelectableChip: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 10)
            .foregroundStyle(isSelected ? Color.white : (isEnabled ? Brand.navy : Color.secondary))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Brand.blue : Brand.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Brand.blue : Brand.cardBorder, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Quantity input with large − / + buttons, so most changes need no typing.
struct QuantityField: View {
    @Binding var text: String
    var allowsFractions: Bool
    var minimum: Decimal = 0
    var accessibilityTitle: LocalizedStringKey = "כמות"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 12) {
            stepButton(systemImage: "minus", step: -1)
                .accessibilityLabel(Text("הפחתה"))
            TextField("0", text: $text)
                .keyboardType(allowsFractions ? .decimalPad : .numberPad)
                .multilineTextAlignment(.center)
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
                .frame(minHeight: 56)
                .background(Brand.blueSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused(focus)
                .accessibilityLabel(Text(accessibilityTitle))
                .environment(\.layoutDirection, .leftToRight)
            stepButton(systemImage: "plus", step: 1)
                .accessibilityLabel(Text("הוספה"))
        }
    }

    private func stepButton(systemImage: String, step: Decimal) -> some View {
        Button {
            let current = QuantityParser.parse(text)?.value ?? 0
            let next = max(minimum, current + step)
            text = QuantityFormatter.editableString(next)
        } label: {
            Image(systemName: systemImage)
                .font(.title2.weight(.bold))
                .frame(width: 56, height: 56)
                .foregroundStyle(Brand.blue)
                .background(Brand.blueSoft, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Button label that turns into a spinner while saving.
struct ProgressLabel: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let isLoading: Bool

    var body: some View {
        ZStack {
            Label {
                Text(title)
            } icon: {
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .opacity(isLoading ? 0 : 1)
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel(Text("שומר…"))
            }
        }
    }
}

/// Banner for connection and sync status.
struct StatusBanner: View {
    enum Kind {
        case offline
        case warning
        case info
    }

    let kind: Kind
    let title: String
    var message: String?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.navy)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blue)
                    .frame(minHeight: 44)
            }
        }
        .padding(14)
        .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch kind {
        case .offline: return "wifi.slash"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch kind {
        case .offline: return .secondary
        case .warning: return Brand.goldText
        case .info: return Brand.blue
        }
    }

    private var background: Color {
        switch kind {
        case .offline: return Color(uiColor: .tertiarySystemFill)
        case .warning: return Brand.gold.opacity(0.18)
        case .info: return Brand.blueSoft
        }
    }
}

/// Toast overlay shown at the top of the app.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
            Text(toast.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.navy)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var icon: String {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "clock.arrow.circlepath"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .success: return Brand.green
        case .info: return Brand.blue
        case .warning: return Brand.goldText
        case .error: return Brand.danger
        }
    }
}

/// Small rounded tag ("אזל מהמלאי", "ממתין לסנכרון").
struct TagView: View {
    let text: String
    var systemImage: String?
    var tint: Color = Brand.blue
    var background: Color = Brand.blueSoft

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
    }
}
