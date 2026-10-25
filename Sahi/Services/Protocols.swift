import Foundation

/// Live change notifications from the backend.
enum RealtimeEvent: Equatable, Sendable {
    /// A row changed in one of the shared tables.
    case tableChanged(String)
    /// The realtime subscription connected (true) or dropped (false).
    case connection(Bool)
}

/// The shared inventory. The cloud database is the source of truth; every
/// write goes through server functions that validate and lock atomically.
protocol InventoryRepository: AnyObject, Sendable {
    func fetchUnits() async throws -> [MeasurementUnit]
    func fetchCategories() async throws -> [ProductCategory]
    func fetchInventory(includeArchived: Bool) async throws -> [InventoryItem]
    func fetchActivity(productId: UUID?, limit: Int) async throws -> [ActivityEntry]

    func addStock(_ request: AddStockRequest) async throws -> StockChangeResult
    func adjustStock(_ request: AdjustStockRequest) async throws -> StockChangeResult
    func setStock(_ request: SetStockRequest) async throws -> StockChangeResult
    func updateProduct(_ request: UpdateProductRequest) async throws
    func archiveProduct(id: UUID, reason: String?) async throws
    func restoreProduct(id: UUID) async throws

    /// Stream of change notifications; cancelling the consuming task unsubscribes.
    func realtimeEvents() -> AsyncStream<RealtimeEvent>
}

enum SignUpOutcome: Equatable, Sendable {
    case signedIn
    /// The project requires email confirmation before the first sign-in.
    case confirmationRequired
}

enum AuthState: Equatable, Sendable {
    case signedOut
    case signedIn(userId: UUID, email: String?)
}

protocol AuthService: AnyObject, Sendable {
    func authStates() -> AsyncStream<AuthState>
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome
    func sendPasswordReset(email: String) async throws
    func signOut() async throws
}

protocol ProfileRepository: AnyObject, Sendable {
    func fetchProfile(userId: UUID) async throws -> UserProfile?
    /// Returns nil on success, or the reason the code was not accepted.
    func joinWithCode(_ code: String) async throws -> AppError?
    func updateDisplayName(_ name: String) async throws -> UserProfile
}

protocol AdminRepository: AnyObject, Sendable {
    func listMembers() async throws -> [Member]
    func updateMember(id: UUID, role: MemberRole, isActive: Bool) async throws
    func setJoinCode(_ code: String) async throws
}
