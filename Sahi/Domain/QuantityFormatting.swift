import Foundation

/// Parses quantities typed by volunteers. Accepts "12", "2.5" and "2,5";
/// rejects anything else (letters, signs, several separators).
enum QuantityParser {
    struct Parsed: Equatable {
        let value: Decimal
        let fractionDigits: Int
    }

    static func parse(_ text: String) -> Parsed? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "٫", with: ".")
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return nil }

        var separators = 0
        for character in trimmed {
            if character == "." {
                separators += 1
            } else if let ascii = character.asciiValue, (48...57).contains(ascii) {
                continue
            } else {
                return nil
            }
        }
        guard separators <= 1, trimmed.first != ".", trimmed.last != "." else { return nil }

        guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let fractionDigits = trimmed.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        return Parsed(value: value, fractionDigits: fractionDigits)
    }
}

enum QuantityFormatter {
    /// "12", "2.5", "0.125" — no grouping noise for small numbers, up to 3 decimals.
    static func string(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)).locale(AppLocale.current))
    }

    /// Plain text for an input field ("2.5"), independent of locale.
    static func editableString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value.sahiRounded(scale: 3)).stringValue
    }

    /// "+5" / "−3" for history rows.
    static func signed(_ value: Decimal) -> String {
        if value > 0 { return "+" + string(value) }
        if value < 0 { return "−" + string(-value) }
        return string(value)
    }

    static func withUnit(_ value: Decimal, _ unit: MeasurementUnit) -> String {
        "\(string(value)) \(unit.displayName)"
    }
}

extension Date {
    /// "לפני 5 דקות" for recent changes, a full date for older ones.
    var sahiRelativeDescription: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 45 {
            return String(localized: "עכשיו")
        }
        if interval < 7 * 24 * 3600 {
            return formatted(.relative(presentation: .named).locale(AppLocale.current))
        }
        return formatted(.dateTime.day().month(.abbreviated).year().locale(AppLocale.current))
    }

    /// "25 באוק׳ 2026, 14:03"
    var sahiDateTime: String {
        formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(AppLocale.current))
    }

    var sahiTime: String {
        formatted(.dateTime.hour().minute().locale(AppLocale.current))
    }
}
