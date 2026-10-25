import Foundation
import os

/// Unified logging. Never log tokens, passwords, emails or join codes;
/// error descriptions are logged as public, identifiers as private.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "org.sahi.inventory"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let inventory = Logger(subsystem: subsystem, category: "inventory")
    static let realtime = Logger(subsystem: subsystem, category: "realtime")
    static let sync = Logger(subsystem: subsystem, category: "sync")
}
