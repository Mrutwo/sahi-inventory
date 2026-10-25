import Foundation

/// Every error the UI can show, with a clear Hebrew message.
enum AppError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case notAuthenticated
    case notMember
    case accountDisabled
    case notAdmin
    case invalidName
    case invalidQuantity
    case quantityTooLarge
    case wholeNumberRequired
    case invalidUnit
    case invalidCategory
    case notesTooLong
    case productNotFound
    case productArchived
    case insufficientStock
    case versionConflict
    case duplicateProduct
    case unsafeUnitChange
    case invalidJoinCode
    case joinCodeNotConfigured
    case tooManyAttempts
    case lastAdmin
    case invalidDisplayName
    case invalidCredentials
    case emailNotConfirmed
    case emailAlreadyRegistered
    case weakPassword
    case rateLimited
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "האפליקציה עדיין לא חוברה לשרת.")
        case .offline: return String(localized: "אין חיבור לאינטרנט. נסו שוב כשהחיבור יחזור.")
        case .notAuthenticated: return String(localized: "יש להתחבר מחדש.")
        case .notMember: return String(localized: "החשבון עדיין לא אושר להצטרפות למלאי המשותף.")
        case .accountDisabled: return String(localized: "הגישה של החשבון הזה הושבתה. לפרטים פנו לרכז/ת המתנדבים.")
        case .notAdmin: return String(localized: "הפעולה הזו מותרת רק למנהלים.")
        case .invalidName: return String(localized: "שם המוצר לא תקין.")
        case .invalidQuantity: return String(localized: "הכמות לא תקינה.")
        case .quantityTooLarge: return String(localized: "הכמות גדולה מדי.")
        case .wholeNumberRequired: return String(localized: "ביחידת המידה הזו יש להזין מספר שלם.")
        case .invalidUnit: return String(localized: "יחידת המידה לא תקינה.")
        case .invalidCategory: return String(localized: "הקטגוריה לא תקינה.")
        case .notesTooLong: return String(localized: "ההערה ארוכה מדי.")
        case .productNotFound: return String(localized: "המוצר לא נמצא. ייתכן שהוסר.")
        case .productArchived: return String(localized: "המוצר הוסר מהמלאי הפעיל.")
        case .insufficientStock: return String(localized: "אין מספיק במלאי לביצוע ההוצאה.")
        case .versionConflict: return String(localized: "מתנדב/ת אחר/ת עדכנ/ה את המוצר בינתיים. הנתונים רועננו — בדקו ונסו שוב.")
        case .duplicateProduct: return String(localized: "כבר קיים מוצר בשם הזה ובאותה יחידת מידה.")
        case .unsafeUnitChange: return String(localized: "אי אפשר לשנות יחידת מידה כשיש מלאי, למעט המרה בין ק\"ג לגרם. אפסו את המלאי או בחרו יחידה תואמת.")
        case .invalidJoinCode: return String(localized: "קוד ההצטרפות שגוי.")
        case .joinCodeNotConfigured: return String(localized: "עדיין לא הוגדר קוד הצטרפות. פנו לרכז/ת המתנדבים.")
        case .tooManyAttempts: return String(localized: "יותר מדי ניסיונות. נסו שוב בעוד 15 דקות.")
        case .lastAdmin: return String(localized: "חייב להישאר לפחות מנהל/ת פעיל/ה אחד/ת.")
        case .invalidDisplayName: return String(localized: "יש להזין שם תצוגה.")
        case .invalidCredentials: return String(localized: "האימייל או הסיסמה שגויים.")
        case .emailNotConfirmed: return String(localized: "יש לאשר את כתובת האימייל דרך הקישור שנשלח אליכם.")
        case .emailAlreadyRegistered: return String(localized: "כתובת האימייל כבר רשומה. נסו להתחבר.")
        case .weakPassword: return String(localized: "הסיסמה חלשה מדי. בחרו לפחות 8 תווים.")
        case .rateLimited: return String(localized: "יותר מדי בקשות. נסו שוב בעוד כמה דקות.")
        case .server: return String(localized: "אירעה שגיאה בשרת. נסו שוב.")
        }
    }

    /// Whether retrying the same request later could succeed.
    var isConnectivityProblem: Bool { self == .offline }

    /// Maps a "SAHI_*" code raised by the database functions.
    static func fromServerCode(_ message: String) -> AppError? {
        let codes: [(String, AppError)] = [
            ("SAHI_NOT_AUTHENTICATED", .notAuthenticated),
            ("SAHI_NOT_MEMBER", .notMember),
            ("SAHI_ACCOUNT_DISABLED", .accountDisabled),
            ("SAHI_NOT_ADMIN", .notAdmin),
            ("SAHI_INVALID_NAME", .invalidName),
            ("SAHI_INVALID_QUANTITY", .invalidQuantity),
            ("SAHI_QUANTITY_TOO_LARGE", .quantityTooLarge),
            ("SAHI_WHOLE_NUMBER_REQUIRED", .wholeNumberRequired),
            ("SAHI_INVALID_UNIT", .invalidUnit),
            ("SAHI_INVALID_CATEGORY", .invalidCategory),
            ("SAHI_NOTES_TOO_LONG", .notesTooLong),
            ("SAHI_PRODUCT_NOT_FOUND", .productNotFound),
            ("SAHI_PRODUCT_ARCHIVED", .productArchived),
            ("SAHI_INSUFFICIENT_STOCK", .insufficientStock),
            ("SAHI_VERSION_CONFLICT", .versionConflict),
            ("SAHI_DUPLICATE_PRODUCT", .duplicateProduct),
            ("SAHI_UNSAFE_UNIT_CHANGE", .unsafeUnitChange),
            ("SAHI_INVALID_JOIN_CODE", .invalidJoinCode),
            ("SAHI_LAST_ADMIN", .lastAdmin),
            ("SAHI_INVALID_DISPLAY_NAME", .invalidDisplayName),
        ]
        return codes.first { message.contains($0.0) }?.1
    }

    /// Maps a join_with_code status.
    static func fromJoinStatus(_ status: String) -> AppError? {
        switch status {
        case "joined", "already_member": return nil
        case "invalid_code": return .invalidJoinCode
        case "too_many_attempts": return .tooManyAttempts
        case "not_configured": return .joinCodeNotConfigured
        case "account_disabled": return .accountDisabled
        default: return .server(status)
        }
    }

    /// Generic mapping for errors that are not specific to the backend SDK.
    static func fromGeneric(_ error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed:
                return .offline
            default:
                return .server(urlError.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .offline
        }
        if let code = fromServerCode(nsError.localizedDescription) {
            return code
        }
        return .server(String(describing: error))
    }
}
