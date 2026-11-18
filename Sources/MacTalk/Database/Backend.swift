import Foundation
import MacTalkCore
import Supabase

/// Owns the Supabase client. Created once at launch from Info.plist configuration.
/// The anon key is public by design; Row Level Security and the SQL functions enforce access.
final class Backend: Sendable {
    let client: SupabaseClient
    let configuration: AppConfiguration

    static let decoder: JSONDecoder = PostgrestClient.Configuration.jsonDecoder

    init?(configuration: AppConfiguration) {
        guard configuration.isConfigured, let url = configuration.supabaseURL, let key = configuration.supabaseAnonKey else {
            return nil
        }
        self.configuration = configuration
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: KeychainLocalStorage(service: "app.mactalk.session.\(configuration.environment.rawValue)"),
                    flowType: .pkce,
                    autoRefreshToken: true,
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(logger: nil)
            )
        )
    }

    var currentUserID: UUID? { client.auth.currentSession?.user.id }

    /// Calls a SQL function and maps server error codes to `MacTalkError`.
    func rpc<T: Decodable & Sendable>(_ fn: String, _ params: [String: AnyJSON] = [:], as: T.Type = T.self,
                                      peerName: String = "Your friend") async throws -> T {
        do {
            return try await client.rpc(fn, params: params).execute().value
        } catch {
            throw Self.map(error, peerName: peerName)
        }
    }

    func rpcVoid(_ fn: String, _ params: [String: AnyJSON] = [:]) async throws {
        do {
            try await client.rpc(fn, params: params).execute()
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: Error, peerName: String = "Your friend") -> MacTalkError {
        if let e = error as? MacTalkError { return e }
        if let e = error as? PostgrestError { return .fromServer(message: e.message, detail: e.detail, peerName: peerName) }
        if let e = error as? AuthError {
            switch e {
            case .sessionMissing: return .sessionExpired
            case .api(let message, _, _, _): return .fromServer(message: message)
            default: return .server(e.localizedDescription)
            }
        }
        if let e = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                         .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(e.code) {
            return .network
        }
        if error is CancellationError { return .server("Cancelled") }
        return .server(error.localizedDescription)
    }
}

extension AnyJSON {
    static func uuid(_ id: UUID) -> AnyJSON { .string(id.uuidString.lowercased()) }
}
