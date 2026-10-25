import SwiftUI
import UIKit

/// Colors from the organization's visual identity (sahi-israel.org):
/// primary blue #00529C, light blue #EEF4FA / #C8DCF0, navy text #0D1E3A,
/// mustard accent #EDC11C and green #9CB734. Each color has a dark-mode
/// variant tuned for contrast.
enum Brand {
    static let blue = Color.dynamic(light: 0x00529C, dark: 0x5BA4EE)
    static let blueSoft = Color.dynamic(light: 0xEEF4FA, dark: 0x13263D)
    static let blueMid = Color.dynamic(light: 0xC8DCF0, dark: 0x24456B)
    static let navy = Color.dynamic(light: 0x0D1E3A, dark: 0xE8EEF7)
    static let gold = Color.dynamic(light: 0xEDC11C, dark: 0xF2CD45)
    /// Gold dark enough for text on light backgrounds.
    static let goldText = Color.dynamic(light: 0x8A6A00, dark: 0xF2CD45)
    static let green = Color.dynamic(light: 0x5F7A12, dark: 0xB5D04E)
    static let greenSoft = Color.dynamic(light: 0xF3F6E7, dark: 0x1E2A10)
    static let danger = Color(uiColor: .systemRed)

    static let background = Color.dynamic(light: 0xF4F7FB, dark: 0x0A111C)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x152132)
    static let cardBorder = Color.dynamic(light: 0xE2ECF7, dark: 0x22334A)
}

extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Theme preference from Settings.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "לפי המכשיר")
        case .light: return String(localized: "בהיר")
        case .dark: return String(localized: "כהה")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let storageKey = "appearance"
}

// MARK: - Card style

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Brand.cardBorder, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Brand.blue
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(
                tint.opacity(isEnabled ? 1 : 0.45),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Brand.blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(Brand.blueSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var sahiPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func sahiPrimary(tint: Color) -> PrimaryButtonStyle { PrimaryButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var sahiSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
