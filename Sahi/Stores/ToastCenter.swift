import Foundation
import Observation

struct Toast: Equatable, Identifiable {
    enum Style: Equatable {
        case success
        case info
        case warning
        case error
    }

    let id = UUID()
    let message: String
    let style: Style
}

/// Short confirmation messages shown at the top of the screen.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: Toast?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ message: String, style: Toast.Style = .success) {
        let toast = Toast(message: message, style: style)
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(style == .error ? 4 : 2.6))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
