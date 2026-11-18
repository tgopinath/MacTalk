import Foundation
import MacTalkCore

/// Owns the Firebase clients. Created once at launch from Info.plist configuration.
@MainActor
final class Backend {
    let configuration: AppConfiguration
    let auth: FirebaseAuthClient
    let db: RealtimeDatabase

    init?(configuration: AppConfiguration) {
        guard configuration.isConfigured, let key = configuration.firebaseAPIKey,
              let dbURL = configuration.databaseURL, let page = configuration.authPageURL else { return nil }
        self.configuration = configuration
        auth = FirebaseAuthClient(apiKey: key, authPage: page, environment: configuration.environment)
        db = RealtimeDatabase(baseURL: dbURL, auth: auth)
    }

    var currentUserID: UserID? { auth.uid }
    var currentEmail: String? { auth.session?.email }
    var myEmailKey: String? { currentEmail.map(EmailKey.of) }

    static func map(_ error: Error) -> MacTalkError {
        if let e = error as? MacTalkError { return e }
        if let e = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                         .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(e.code) {
            return .network
        }
        return .server(error.localizedDescription)
    }
}
