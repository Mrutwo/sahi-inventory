import SwiftUI
import UIKit

@main
struct SahiApp: App {
    @State private var environment = AppEnvironment.live()
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system

    init() {
        // Make UIKit chrome (navigation and tab bars, sheets) follow the app's
        // language direction even when the device language is LTR.
        if AppLocale.layoutDirection == .rightToLeft {
            UIView.appearance().semanticContentAttribute = .forceRightToLeft
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch environment.mode {
                case .live(let session):
                    RootView()
                        .environment(session)
                        .environment(session.inventory)
                case .notConfigured:
                    SetupRequiredView()
                case .testing:
                    Color.clear
                }
            }
            .environment(environment.toasts)
            .environment(environment.network)
            .environment(\.locale, AppLocale.current)
            .environment(\.layoutDirection, AppLocale.layoutDirection)
            .fontDesign(.rounded)
            .tint(Brand.blue)
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}
