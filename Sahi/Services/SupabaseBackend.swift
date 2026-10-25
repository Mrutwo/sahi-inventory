import Foundation
import Supabase

/// Supabase implementation of the inventory, profile, admin and auth services.
///
/// Reads go to the security-invoker views (`inventory_items`, `activity_feed`)
/// so row-level security applies; writes go exclusively through the RPC
/// functions defined in supabase/migrations.
final class SupabaseBackend: InventoryRepository, ProfileRepository, AdminRepository, AuthService, @unchecked Sendable {
    let client: SupabaseClient

    init(config: AppConfig, authStorageKey: String? = nil) {
        client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: .init(storageKey: authStorageKey, emitLocalSessionAsInitialSession: true)
            )
        )
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: data)
    }

    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    // MARK: - InventoryRepository

    func fetchUnits() async throws -> [MeasurementUnit] {
        try await perform {
            let response = try await client.from("units").select().order("sort_order").execute()
            return try decode([MeasurementUnit].self, from: response.data)
        }
    }

    func fetchCategories() async throws -> [ProductCategory] {
        try await perform {
            let response = try await client.from("categories").select().order("sort_order").execute()
            return try decode([ProductCategory].self, from: response.data)
        }
    }

    func fetchInventory(includeArchived: Bool) async throws -> [InventoryItem] {
        try await perform {
            let query = client.from("inventory_items").select()
            let response: PostgrestResponse<Void>
            if includeArchived {
                response = try await query.order("name").execute()
            } else {
                response = try await query.eq("is_active", value: true).order("name").execute()
            }
            return try decode([InventoryItem].self, from: response.data)
        }
    }

    func fetchActivity(productId: UUID?, limit: Int) async throws -> [ActivityEntry] {
        try await perform {
            let query = client.from("activity_feed").select()
            let response: PostgrestResponse<Void>
            if let productId {
                response = try await query.eq("product_id", value: productId)
                    .order("created_at", ascending: false)
                    .order("id", ascending: false)
                    .limit(limit)
                    .execute()
            } else {
                response = try await query
                    .order("created_at", ascending: false)
                    .order("id", ascending: false)
                    .limit(limit)
                    .execute()
            }
            return try decode([ActivityEntry].self, from: response.data)
        }
    }

    func addStock(_ request: AddStockRequest) async throws -> StockChangeResult {
        try await perform {
            let response = try await client.rpc("add_stock", params: request).execute()
            return try decode(StockChangeResult.self, from: response.data)
        }
    }

    func adjustStock(_ request: AdjustStockRequest) async throws -> StockChangeResult {
        try await perform {
            let response = try await client.rpc("adjust_stock", params: request).execute()
            return try decode(StockChangeResult.self, from: response.data)
        }
    }

    func setStock(_ request: SetStockRequest) async throws -> StockChangeResult {
        try await perform {
            let response = try await client.rpc("set_stock", params: request).execute()
            return try decode(StockChangeResult.self, from: response.data)
        }
    }

    func updateProduct(_ request: UpdateProductRequest) async throws {
        try await perform {
            _ = try await client.rpc("update_product", params: request).execute()
        }
    }

    func archiveProduct(id: UUID, reason: String?) async throws {
        try await perform {
            _ = try await client.rpc("archive_product", params: ArchiveParams(productId: id, reason: reason)).execute()
        }
    }

    func restoreProduct(id: UUID) async throws {
        try await perform {
            _ = try await client.rpc("restore_product", params: ProductIdParams(productId: id)).execute()
        }
    }

    func realtimeEvents() -> AsyncStream<RealtimeEvent> {
        let client = self.client
        let channel = client.channel("sahi-inventory-\(UUID().uuidString.prefix(8))")
        let tables = ["inventory", "products", "stock_movements", "categories", "profiles"]
        // Streams must be registered before subscribing.
        let changeStreams = tables.map { table in
            (table, channel.postgresChange(AnyAction.self, schema: "public", table: table))
        }
        let statusStream = channel.statusChange

        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for (table, stream) in changeStreams {
                        group.addTask {
                            for await _ in stream {
                                continuation.yield(.tableChanged(table))
                            }
                        }
                    }
                    group.addTask {
                        for await status in statusStream {
                            continuation.yield(.connection(status == .subscribed))
                        }
                    }
                    group.addTask {
                        do {
                            try await channel.subscribeWithError()
                        } catch {
                            Log.realtime.error("Realtime subscribe failed: \(error.localizedDescription, privacy: .public)")
                            continuation.yield(.connection(false))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await client.removeChannel(channel) }
            }
        }
    }

    // MARK: - ProfileRepository

    func fetchProfile(userId: UUID) async throws -> UserProfile? {
        try await perform {
            let response = try await client.from("profiles").select().eq("id", value: userId).limit(1).execute()
            return try decode([UserProfile].self, from: response.data).first
        }
    }

    func joinWithCode(_ code: String) async throws -> AppError? {
        try await perform {
            let response = try await client.rpc("join_with_code", params: JoinParams(code: code)).execute()
            let result = try decode(JoinResult.self, from: response.data)
            return AppError.fromJoinStatus(result.status)
        }
    }

    func updateDisplayName(_ name: String) async throws -> UserProfile {
        try await perform {
            let response = try await client.rpc("update_my_profile", params: DisplayNameParams(displayName: name)).execute()
            return try decode(UserProfile.self, from: response.data)
        }
    }

    // MARK: - AdminRepository

    func listMembers() async throws -> [Member] {
        try await perform {
            let response = try await client.rpc("admin_list_members").execute()
            return try decode([Member].self, from: response.data)
        }
    }

    func updateMember(id: UUID, role: MemberRole, isActive: Bool) async throws {
        try await perform {
            _ = try await client.rpc(
                "admin_update_member",
                params: UpdateMemberParams(userId: id, role: role, isActive: isActive)
            ).execute()
        }
    }

    func setJoinCode(_ code: String) async throws {
        try await perform {
            _ = try await client.rpc("admin_set_join_code", params: JoinParams(code: code)).execute()
        }
    }

    // MARK: - AuthService

    func authStates() -> AsyncStream<AuthState> {
        let auth = client.auth
        return AsyncStream { continuation in
            let task = Task {
                for await (event, session) in auth.authStateChanges {
                    switch event {
                    case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                        if let session, !(event == .initialSession && session.isExpired) {
                            continuation.yield(.signedIn(userId: session.user.id, email: session.user.email))
                        } else if event == .initialSession, let session {
                            // Expired local session: try to refresh before deciding.
                            do {
                                let refreshed = try await auth.refreshSession(refreshToken: session.refreshToken)
                                continuation.yield(.signedIn(userId: refreshed.user.id, email: refreshed.user.email))
                            } catch {
                                let mapped = SupabaseErrorMapper.map(error)
                                if mapped == .offline {
                                    // Keep the volunteer signed in offline; cached data stays visible.
                                    continuation.yield(.signedIn(userId: session.user.id, email: session.user.email))
                                } else {
                                    continuation.yield(.signedOut)
                                }
                            }
                        } else {
                            continuation.yield(.signedOut)
                        }
                    case .signedOut, .userDeleted:
                        continuation.yield(.signedOut)
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func signIn(email: String, password: String) async throws {
        try await perform {
            _ = try await client.auth.signIn(email: email, password: password)
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        try await perform {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["display_name": .string(displayName)]
            )
            switch response {
            case .session: return .signedIn
            case .user: return .confirmationRequired
            }
        }
    }

    func sendPasswordReset(email: String) async throws {
        try await perform {
            try await client.auth.resetPasswordForEmail(email)
        }
    }

    func signOut() async throws {
        await client.removeAllChannels()
        do {
            try await client.auth.signOut()
        } catch {
            // Signing out must always work locally, even offline.
            try? await client.auth.signOut(scope: .local)
            Log.auth.notice("Remote sign-out failed; signed out locally: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - RPC parameter types

private struct ArchiveParams: Encodable, Sendable {
    let productId: UUID
    let reason: String?
    enum CodingKeys: String, CodingKey {
        case productId = "p_product_id"
        case reason = "p_reason"
    }
}

private struct ProductIdParams: Encodable, Sendable {
    let productId: UUID
    enum CodingKeys: String, CodingKey { case productId = "p_product_id" }
}

private struct JoinParams: Encodable, Sendable {
    let code: String
    enum CodingKeys: String, CodingKey { case code = "p_code" }
}

private struct JoinResult: Decodable {
    let status: String
}

private struct DisplayNameParams: Encodable, Sendable {
    let displayName: String
    enum CodingKeys: String, CodingKey { case displayName = "p_display_name" }
}

private struct UpdateMemberParams: Encodable, Sendable {
    let userId: UUID
    let role: MemberRole
    let isActive: Bool
    enum CodingKeys: String, CodingKey {
        case userId = "p_user_id"
        case role = "p_role"
        case isActive = "p_is_active"
    }
}

// MARK: - Error mapping

enum SupabaseErrorMapper {
    static func map(_ error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let postgrest = error as? PostgrestError {
            if let mapped = AppError.fromServerCode(postgrest.message) { return mapped }
            if postgrest.code == "PGRST301" || postgrest.message.localizedCaseInsensitiveContains("JWT expired") {
                return .notAuthenticated
            }
            return .server(postgrest.message)
        }
        if let auth = error as? AuthError {
            switch auth.errorCode {
            case .invalidCredentials: return .invalidCredentials
            case .emailNotConfirmed: return .emailNotConfirmed
            case .userAlreadyExists, .emailExists: return .emailAlreadyRegistered
            case .weakPassword: return .weakPassword
            case .overEmailSendRateLimit, .overRequestRateLimit: return .rateLimited
            case .sessionNotFound: return .notAuthenticated
            default: return .server(auth.message)
            }
        }
        return AppError.fromGeneric(error)
    }
}
