import SwiftUI

/// Chooses the screen for the current session state.
struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(InventoryStore.self) private var inventory
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            switch session.state {
            case .loading:
                LaunchView()
            case .signedOut:
                WelcomeView()
            case .needsJoin(let profile):
                JoinView(profile: profile)
            case .disabled(let profile):
                AccessRevokedView(profile: profile)
            case .active:
                MainTabView()
            case .failed(let error):
                ProfileErrorView(error: error)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.state)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                inventory.resume()
                if session.profile != nil {
                    Task { await session.refreshProfile() }
                }
            }
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 20) {
            SahiLogoView(size: 110)
            ProgressView()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("טוען…"))
    }
}

private struct ProfileErrorView: View {
    @Environment(SessionStore.self) private var session
    let error: AppError
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 20) {
            SahiLogoView(size: 80)
            Text("לא הצלחנו לטעון את החשבון")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(error.localizedDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                isRetrying = true
                Task {
                    await session.refreshProfile()
                    isRetrying = false
                }
            } label: {
                ProgressLabel(title: "ניסיון חוזר", systemImage: "arrow.clockwise", isLoading: isRetrying)
            }
            .buttonStyle(.sahiPrimary)
            .disabled(isRetrying)
            Button("התנתקות") {
                Task { await session.signOut() }
            }
            .frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: 480)
    }
}
