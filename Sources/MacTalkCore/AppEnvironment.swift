import Foundation

public enum AppEnvironment: String, Sendable, CaseIterable {
    case development, staging, production
}

/// Values injected into Info.plist at build time from Config/<env>.env.
/// Only the public anon key lives in the app; all secrets stay in Edge Function secrets.
public struct AppConfiguration: Sendable, Equatable {
    public var environment: AppEnvironment
    public var supabaseURL: URL?
    public var supabaseAnonKey: String?

    public init(environment: AppEnvironment, supabaseURL: URL?, supabaseAnonKey: String?) {
        self.environment = environment; self.supabaseURL = supabaseURL; self.supabaseAnonKey = supabaseAnonKey
    }

    public init(infoDictionary: [String: Any]) {
        let env = AppEnvironment(rawValue: (infoDictionary["MacTalkEnvironment"] as? String ?? "").lowercased()) ?? .development
        let url = (infoDictionary["MacTalkSupabaseURL"] as? String).flatMap { $0.nonEmpty }.flatMap(URL.init(string:))
        let key = (infoDictionary["MacTalkSupabaseAnonKey"] as? String)?.nonEmpty
        self.init(environment: env, supabaseURL: url, supabaseAnonKey: key)
    }

    public var isConfigured: Bool {
        guard let supabaseURL, let supabaseAnonKey else { return false }
        return supabaseURL.scheme == "https" && !supabaseAnonKey.contains("YOUR_") && supabaseAnonKey.count > 20
    }
}
