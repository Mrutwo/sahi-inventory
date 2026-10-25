import Foundation

enum MemberRole: String, Codable, Sendable, CaseIterable {
    case pending
    case volunteer
    case admin

    var title: String {
        switch self {
        case .pending: return String(localized: "ממתין/ה לאישור")
        case .volunteer: return String(localized: "מתנדב/ת")
        case .admin: return String(localized: "מנהל/ת")
        }
    }
}

struct UserProfile: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var role: MemberRole
    var isActive: Bool
    var createdAt: Date

    var isMember: Bool { isActive && role != .pending }
    var isAdmin: Bool { isActive && role == .admin }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case role
        case isActive = "is_active"
        case createdAt = "created_at"
    }
}

/// A volunteer as seen by an admin (includes the sign-in email).
struct Member: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var email: String?
    var role: MemberRole
    var isActive: Bool
    var createdAt: Date
    var lastSignInAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case email
        case role
        case isActive = "is_active"
        case createdAt = "created_at"
        case lastSignInAt = "last_sign_in_at"
    }
}
