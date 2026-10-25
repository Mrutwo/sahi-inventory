import Foundation

/// Decides when a stock change is significant enough to ask "are you sure?".
enum StockChangeGuard {
    enum Reason: Equatable {
        /// The stock would reach zero.
        case emptiesStock
        /// At least half of the stock (and at least 5) would be removed.
        case largeDecrease(percent: Int)
        /// An unusually large amount is being added (often a typo, 500 instead of 50).
        case largeIncrease

        var message: String {
            switch self {
            case .emptiesStock:
                return String(localized: "הפעולה תאפס את המלאי של המוצר. המוצר וההיסטוריה שלו יישארו.")
            case .largeDecrease(let percent):
                return String(localized: "הפעולה תוריד \(percent)% מהמלאי של המוצר.")
            case .largeIncrease:
                return String(localized: "זו כמות גדולה במיוחד. ודאו שאין טעות הקלדה.")
            }
        }
    }

    static let minimumSignificantDecrease: Decimal = 5
    static let largeIncreaseThreshold: Decimal = 500

    static func confirmationReason(current: Decimal, new: Decimal) -> Reason? {
        let delta = new - current
        if delta < 0 {
            if new == 0 { return .emptiesStock }
            let removed = -delta
            if current > 0, removed >= minimumSignificantDecrease, removed * 2 >= current {
                let percent = NSDecimalNumber(decimal: (removed / current * 100).sahiRounded(scale: 0)).intValue
                return .largeDecrease(percent: percent)
            }
            return nil
        }
        if delta >= largeIncreaseThreshold {
            return .largeIncrease
        }
        return nil
    }
}
