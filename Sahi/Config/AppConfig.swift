import Foundation

/// Backend connection settings, read from Info.plist (filled from
/// Config/Secrets.xcconfig at build time). Only the public "anon" key belongs
/// in the app — access is enforced by row-level security on the server.
/// Never put a service-role key here.
struct AppConfig: Equatable, Sendable {
    let supabaseURL: URL
    let supabaseAnonKey: String

    static let organizationWebsite = URL(string: "https://sahi-israel.org/he/home")!

    static func load(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfig? {
        // Environment variables allow pointing a test run at another project.
        if let url = environment["SAHI_SUPABASE_URL"].flatMap(URL.init(string:)),
           let key = environment["SAHI_SUPABASE_ANON_KEY"], !key.isEmpty {
            return AppConfig(supabaseURL: url, supabaseAnonKey: key)
        }

        let urlString = (bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return make(urlString: urlString, key: key)
    }

    /// Validates raw values; rejects empty or placeholder settings.
    static func make(urlString: String, key: String) -> AppConfig? {
        guard !key.isEmpty, !key.contains("$("), !key.contains("YOUR_") else { return nil }
        guard let url = URL(string: urlString),
              let scheme = url.scheme, ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, !host.contains("YOUR-PROJECT")
        else { return nil }
        return AppConfig(supabaseURL: url, supabaseAnonKey: key)
    }
}
