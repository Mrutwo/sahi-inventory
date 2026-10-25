import Foundation
import SwiftUI

/// The language the app is actually running in (its best-matching
/// localization, Hebrew by default) — not necessarily the device language.
/// Dates and numbers are formatted with it so a Hebrew UI never shows,
/// say, Russian month names.
///
/// To add a language later (e.g. Russian or English): add it in the project's
/// localizations, translate Localizable.xcstrings, and list it here.
enum AppLocale {
    static let supportedLanguages = ["he", "en", "ru"]

    static var languageCode: String {
        let preferred = Bundle.main.preferredLocalizations
            .map { String($0.prefix(2)).lowercased() }
            .first { supportedLanguages.contains($0) }
        return preferred ?? "he"
    }

    static var current: Locale {
        Locale(identifier: languageCode == "he" ? "he_IL" : languageCode)
    }

    static var layoutDirection: LayoutDirection {
        Locale.Language(identifier: languageCode).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}
