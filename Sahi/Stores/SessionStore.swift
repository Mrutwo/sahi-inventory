import Foundation
import Observation

/// Who is signed in and whether they may use the shared inventory.
@MainActor
@Observable
final class SessionStore {
    enum State: Equatable {
        case loading
        case signedOut
        /// Signed in, but not yet approved: must enter the join code.
        case needsJoin(UserProfile)
        /// Access was revoked by an admin.
        case disabled(UserProfile)
        case active(UserProfile)
        /// Could not load the profile (and no cached copy is available).
        case failed(AppError)
    }

    private(set) var state: State = .loading
    private(set) var email: String?

    let inventory: InventoryStore
    let admin: AdminRepository

    @ObservationIgnored private let auth: AuthService
    @ObservationIgnored private let profiles: ProfileRepository
    @ObservationIgnored private let localStore: LocalStore
    @ObservationIgnored private var userId: UUID?
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var profileRefreshTask: Task<Void, Never>?

    init(auth: AuthService, profiles: ProfileRepository, admin: AdminRepository, inventory: InventoryStore, localStore: LocalStore = .standard) {
        self.auth = auth
        self.profiles = profiles
        self.admin = admin
        self.inventory = inventory
        self.localStore = localStore
        inventory.onMembershipShouldRefresh = { [weak self] in
            self?.scheduleProfileRefresh()
        }
    }

    var profile: UserProfile? {
        switch state {
        case .needsJoin(let profile), .disabled(let profile), .active(let profile): return profile
        case .loading, .signedOut, .failed: return nil
        }
    }

    var isAdmin: Bool { profile?.isAdmin ?? false }

    func start() {
        guard authTask == nil else { return }
        authTask = Task { [weak self] in
            guard let states = self?.auth.authStates() else { return }
            for await authState in states {
                await self?.handle(authState)
            }
        }
    }

    // MARK: - Auth actions

    func signIn(email: String, password: String) async throws {
        try await auth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        try await auth.signUp(
            email: email.trimmingCharacters(in: .whitespaces),
            password: password,
            displayName: ProductNameNormalizer.displayName(displayName)
        )
    }

    func sendPasswordReset(email: String) async throws {
        try await auth.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
    }

    func signOut() async {
        let previousUser = userId
        try? await auth.signOut()
        // The auth stream also reports this; doing it here makes sign-out
        // immediate even if the stream is slow.
        clearSession(previousUser: previousUser)
    }

    func join(code: String) async throws {
        let problem = try await profiles.joinWithCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
        if let problem {
            throw problem
        }
        await refreshProfile()
    }

    func updateDisplayName(_ name: String) async throws {
        let updated = try await profiles.updateDisplayName(ProductNameNormalizer.displayName(name))
        apply(updated)
    }

    // MARK: - Profile

    func refreshProfile() async {
        guard let userId else { return }
        do {
            guard let profile = try await profiles.fetchProfile(userId: userId) else {
                state = .failed(.notMember)
                return
            }
            guard self.userId == userId else { return }
            localStore.save(profile, to: Self.profileCacheName)
            apply(profile)
        } catch {
            let appError = (error as? AppError) ?? AppError.fromGeneric(error)
            Log.auth.error("Profile load failed: \(appError.localizedDescription, privacy: .public)")
            if case .active = state { return } // keep working with what we have
            if let cached = localStore.load(UserProfile.self, from: Self.profileCacheName), cached.id == userId {
                apply(cached)
            } else {
                state = .failed(appError)
            }
        }
    }

    private func scheduleProfileRefresh() {
        profileRefreshTask?.cancel()
        profileRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshProfile()
        }
    }

    private func handle(_ authState: AuthState) async {
        switch authState {
        case .signedOut:
            clearSession(previousUser: userId)
        case let .signedIn(newUserId, newEmail):
            email = newEmail
            if userId == newUserId, profile != nil {
                return // token refresh for the same volunteer
            }
            if let previous = userId, previous != newUserId {
                inventory.reset(clearingCacheFor: previous)
            }
            userId = newUserId
            if case .signedOut = state { state = .loading }
            await refreshProfile()
        }
    }

    private func apply(_ profile: UserProfile) {
        if !profile.isActive {
            state = .disabled(profile)
            inventory.stop()
        } else if profile.role == .pending {
            state = .needsJoin(profile)
            inventory.stop()
        } else {
            state = .active(profile)
            inventory.start(userId: profile.id)
        }
    }

    private func clearSession(previousUser: UUID?) {
        inventory.reset(clearingCacheFor: previousUser)
        localStore.remove(Self.profileCacheName)
        userId = nil
        email = nil
        state = .signedOut
    }

    private static let profileCacheName = "profile-cache.json"
}
