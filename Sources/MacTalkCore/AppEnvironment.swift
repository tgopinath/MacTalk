import Foundation

public enum AppEnvironment: String, Sendable, CaseIterable {
    case development, staging, production
}

/// Values injected into Info.plist at build time from Config/<env>.env.
/// The Firebase web API key is public by design; database.rules.json protects the data.
public struct AppConfiguration: Sendable, Equatable {
    public var environment: AppEnvironment
    public var firebaseAPIKey: String?
    public var databaseURL: URL?
    public var authPageURL: URL?
    /// Optional TURN relay (comma-separated URLs) for networks where peer-to-peer fails.
    public var turnURLs: [String]
    public var turnUsername: String?
    public var turnCredential: String?

    public init(environment: AppEnvironment, firebaseAPIKey: String?, databaseURL: URL?, authPageURL: URL?,
                turnURLs: [String] = [], turnUsername: String? = nil, turnCredential: String? = nil) {
        self.environment = environment; self.firebaseAPIKey = firebaseAPIKey; self.databaseURL = databaseURL
        self.authPageURL = authPageURL; self.turnURLs = turnURLs; self.turnUsername = turnUsername; self.turnCredential = turnCredential
    }

    public init(infoDictionary: [String: Any]) {
        func string(_ key: String) -> String? { (infoDictionary[key] as? String)?.nonEmpty }
        let env = AppEnvironment(rawValue: (string("MacTalkEnvironment") ?? "").lowercased()) ?? .development
        self.init(environment: env,
                  firebaseAPIKey: string("MacTalkFirebaseAPIKey"),
                  databaseURL: string("MacTalkDatabaseURL").flatMap(URL.init(string:)),
                  authPageURL: string("MacTalkAuthPageURL").flatMap(URL.init(string:)),
                  turnURLs: (string("MacTalkTurnURLs") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                  turnUsername: string("MacTalkTurnUsername"),
                  turnCredential: string("MacTalkTurnCredential"))
    }

    public var isConfigured: Bool {
        guard let key = firebaseAPIKey, key.count > 20, !key.contains("YOUR_"),
              databaseURL?.scheme == "https", authPageURL?.scheme == "https" else { return false }
        return true
    }
}
