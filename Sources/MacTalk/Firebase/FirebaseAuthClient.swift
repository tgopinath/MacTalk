import AppKit
import Foundation
import MacTalkCore

/// Firebase Authentication over its REST API (no SDK, so no keychain-sharing entitlement
/// or provisioning profile is needed on macOS).
///
/// Google sign-in: MacTalk opens a small sign-in page on tgopinath.github.io (already an
/// authorized Firebase domain) in the user's browser. The page signs in with Google and
/// hands the short-lived Google ID token back through `mactalk://auth?…`, where it's
/// exchanged for a Firebase session with `accounts:signInWithIdp`. Only the Firebase
/// refresh token is kept, in the macOS Keychain.
@MainActor
final class FirebaseAuthClient {
    struct Session: Codable, Sendable, Equatable {
        var uid: String
        var email: String
        var displayName: String?
        var photoURL: String?
        var idToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private(set) var session: Session?
    var onChange: ((Session?) -> Void)?

    private let apiKey: String
    private let authPage: URL
    private let keychainService: String
    private var pendingState: String?
    private var pendingContinuation: CheckedContinuation<Void, Error>?
    private var refreshTask: Task<String, Error>?

    static let callbackScheme = "mactalk"

    init(apiKey: String, authPage: URL, environment: AppEnvironment) {
        self.apiKey = apiKey
        self.authPage = authPage
        keychainService = "app.mactalk.firebase.\(environment.rawValue)"
        if let data = Keychain.read("session", service: keychainService),
           let stored = try? JSONDecoder().decode(Session.self, from: data) {
            session = stored
        }
    }

    var uid: String? { session?.uid }

    // MARK: Google sign-in

    func signInWithGoogle() async throws {
        let state = UUID().uuidString
        pendingState = state
        var components = URLComponents(url: authPage, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "app", value: "mactalk")]
        guard let url = components.url else { throw MacTalkError.notConfigured }
        pendingContinuation?.resume(throwing: MacTalkError.signInCancelled)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingContinuation = continuation
            NSWorkspace.shared.open(url)
        }
    }

    func cancelPendingSignIn() {
        pendingContinuation?.resume(throwing: MacTalkError.signInCancelled)
        pendingContinuation = nil
        pendingState = nil
    }

    /// Handles `mactalk://auth?state=…&id_token=…` from the sign-in page.
    func handleCallback(_ url: URL) async {
        guard url.scheme == Self.callbackScheme, url.host == "auth" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let continuation = pendingContinuation
        pendingContinuation = nil
        guard let state = value("state"), state == pendingState else {
            continuation?.resume(throwing: MacTalkError.server("That sign-in link has expired. Try again from MacTalk."))
            return
        }
        pendingState = nil
        if let error = value("error") {
            continuation?.resume(throwing: error == "cancelled" ? MacTalkError.signInCancelled : MacTalkError.server(error))
            return
        }
        guard let idToken = value("id_token") else {
            continuation?.resume(throwing: MacTalkError.server("Google didn't return a sign-in token."))
            return
        }
        do {
            try await exchange(googleIDToken: idToken, accessToken: value("access_token"))
            NSApp.activate(ignoringOtherApps: true)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
    }

    private func exchange(googleIDToken: String, accessToken: String?) async throws {
        var postBody = "id_token=\(googleIDToken)&providerId=google.com"
        if let accessToken { postBody += "&access_token=\(accessToken)" }
        struct Response: Decodable {
            let localId: String; let email: String?; let displayName: String?; let photoUrl: String?
            let idToken: String; let refreshToken: String; let expiresIn: String
            let emailVerified: Bool?
        }
        let response: Response = try await post(
            "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp",
            json: ["postBody": postBody, "requestUri": authPage.absoluteString, "returnSecureToken": true, "returnIdpCredential": true])
        guard let email = response.email, response.emailVerified != false else { throw MacTalkError.emailNotVerified }
        store(Session(uid: response.localId, email: email.lowercased(), displayName: response.displayName,
                      photoURL: response.photoUrl, idToken: response.idToken, refreshToken: response.refreshToken,
                      expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn) ?? 3600)))
    }

    // MARK: Tokens

    /// A valid ID token, refreshed when it's within 5 minutes of expiry.
    func idToken(forceRefresh: Bool = false) async throws -> String {
        guard let session else { throw MacTalkError.notAuthenticated }
        if !forceRefresh, session.expiresAt.timeIntervalSinceNow > 300 { return session.idToken }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { () throws -> String in
            defer { self.refreshTask = nil }
            struct Response: Decodable { let id_token: String; let refresh_token: String; let expires_in: String }
            do {
                let r: Response = try await self.postForm("https://securetoken.googleapis.com/v1/token",
                                                          ["grant_type": "refresh_token", "refresh_token": session.refreshToken])
                var updated = session
                updated.idToken = r.id_token
                updated.refreshToken = r.refresh_token
                updated.expiresAt = Date().addingTimeInterval(TimeInterval(r.expires_in) ?? 3600)
                self.store(updated)
                return r.id_token
            } catch let error as MacTalkError where error == .sessionExpired {
                self.signOut()
                throw error
            }
        }
        refreshTask = task
        return try await task.value
    }

    func signOut() {
        session = nil
        Keychain.delete("session", service: keychainService)
        onChange?(nil)
    }

    private func store(_ session: Session) {
        let changedUser = self.session?.uid != session.uid
        self.session = session
        if let data = try? JSONEncoder().encode(session) { Keychain.write(data, account: "session", service: keychainService) }
        if changedUser { onChange?(session) }
    }

    // MARK: HTTP

    private func post<T: Decodable>(_ endpoint: String, json: [String: Any]) async throws -> T {
        var request = URLRequest(url: URL(string: "\(endpoint)?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(request)
    }

    private func postForm<T: Decodable>(_ endpoint: String, _ form: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "\(endpoint)?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw MacTalkError.network }
        guard let http = response as? HTTPURLResponse else { throw MacTalkError.network }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw MacTalkError.fromServer(message: message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
