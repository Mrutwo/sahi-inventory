import SwiftUI

struct MainTabView: View {
    enum AppTab: Hashable {
        case inventory
        case activity
        case settings
    }

    @Environment(ToastCenter.self) private var toasts
    @State private var selection: AppTab = .inventory

    var body: some View {
        TabView(selection: $selection) {
            InventoryView()
                .tabItem { Label("מלאי", systemImage: "shippingbox.fill") }
                .tag(AppTab.inventory)
            ActivityView()
                .tabItem { Label("היסטוריה", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.activity)
            SettingsView()
                .tabItem { Label("הגדרות", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .overlay(alignment: .top) {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { toasts.dismiss() }
                    .id(toast.id)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toasts.current)
        .sensoryFeedback(.success, trigger: toasts.current?.id) { _, _ in
            toasts.current?.style == .success
        }
    }
}
