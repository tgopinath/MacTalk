import AppKit
import Foundation
import MacTalkCore
import Observation

@MainActor @Observable
final class AuthService {
    enum State: Equatable {
        case loading
        case signedOut
        case needsProfile(UserProfile)
        case signedIn(UserProfile)
    }

    private(set) var state: State = .loading {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    var notice: String?
    /// Google photo from the sign-in, offered on the profile step.
    private(set) var googlePhotoURL: String?

    private let backend: Backend
    private var wasSignedIn = false

    init(backend: Backend) {
        self.backend = backend
        backend.auth.onChange = { [weak self] session in
            guard let self else { return }
            if session == nil {
                if self.wasSignedIn { self.notice = MacTalkError.sessionExpired.errorDescription }
                self.wasSignedIn = false
                self.state = .signedOut
            }
        }
        Task { await restore() }
    }

    var profile: UserProfile? {
        switch state {
        case .signedIn(let p), .needsProfile(let p): p
        default: nil
        }
    }

    var userID: UserID? { profile?.id }

    private func restore() async {
        guard backend.auth.session != nil else { state = .signedOut; return }
        await loadProfile()
    }

    /// Reads `users/{uid}`; a first-time user goes to the profile step prefilled from Google.
    func loadProfile() async {
        guard let session = backend.auth.session else { state = .signedOut; return }
        googlePhotoURL = session.photoURL
        do {
            let record: UserRecord? = try await backend.db.get("users/\(session.uid)")
            wasSignedIn = true
            let profile = UserProfile(id: session.uid, email: session.email,
                                      displayName: record?.name ?? session.displayName,
                                      avatarURL: record?.photo ?? session.photoURL,
                                      manualStatus: record?.status ?? .online,
                                      profileCompleted: record?.name?.nonEmpty != nil)
            state = profile.profileCompleted ? .signedIn(profile) : .needsProfile(profile)
        } catch let error as MacTalkError where error == .sessionExpired || error == .notAuthenticated {
            state = .signedOut
        } catch MacTalkError.permissionDenied {
            // Signed in, but the database won't let us read our own profile: setup problem.
            notice = MacTalkError.permissionDenied.errorDescription
            state = .needsProfile(UserProfile(id: session.uid, email: session.email, displayName: session.displayName,
                                              avatarURL: session.photoURL))
        } catch {
            // Offline at launch: keep the cached identity and let presence recover later.
            notice = Backend.map(error).errorDescription
            let profile = UserProfile(id: session.uid, email: session.email, displayName: session.displayName,
                                      avatarURL: session.photoURL, profileCompleted: true)
            wasSignedIn = true
            state = .signedIn(profile)
        }
    }

    func signInWithGoogle() async throws {
        notice = nil
        try await backend.auth.signInWithGoogle()
        await loadProfile()
    }

    func cancelSignIn() { backend.auth.cancelPendingSignIn() }

    func handleOpenURL(_ url: URL) async {
        await backend.auth.handleCallback(url)
    }

    func completeProfile(displayName: String, avatar: AvatarChoice, status: ManualStatus) async throws {
        guard let current = profile else { throw MacTalkError.notAuthenticated }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count) else { throw MacTalkError.server("Choose a name between 1 and 40 characters.") }
        var values: [String: Any] = [
            "users/\(current.id)/name": name,
            "users/\(current.id)/email": current.email,
            "users/\(current.id)/status": status.rawValue,
            "users/\(current.id)/online": true,
            "users/\(current.id)/lastSeen": RealtimeDatabase.serverTimestamp,
        ]
        values["users/\(current.id)/photo"] = avatar.storedValue ?? NSNull()
        do { try await backend.db.update(values) } catch { throw Backend.map(error) }
        await loadProfile()
    }

    func updateProfile(displayName: String, avatar: AvatarChoice?) async throws {
        guard let current = profile else { return }
        try await completeProfile(displayName: displayName, avatar: avatar ?? .existing(current.avatarURL),
                                  status: current.manualStatus)
    }

    func setLocalStatus(_ status: ManualStatus) {
        guard case .signedIn(var p) = state else { return }
        p.manualStatus = status
        state = .signedIn(p)
    }

    func signOut() async {
        if let uid = userID {
            try? await backend.db.update(["users/\(uid)/online": false, "users/\(uid)/inCall": NSNull()])
        }
        wasSignedIn = false
        backend.auth.signOut()
        state = .signedOut
    }

    #if DEBUG
    func debugSetState(_ newState: State) { state = newState }
    #endif
}

enum AvatarChoice: Equatable {
    case existing(String?)
    case preset(AvatarPreset)

    var storedValue: String? {
        switch self {
        case .existing(let url): url
        case .preset(let p): p.encoded
        }
    }
}

/// Built-in avatars stored as "preset:<symbol>:<hue>" so they need no upload.
struct AvatarPreset: Equatable, Hashable, Identifiable {
    var symbol: String
    var hue: Double
    var id: String { encoded }
    var encoded: String { "preset:\(symbol):\(Int(hue * 360))" }

    init(symbol: String, hue: Double) { self.symbol = symbol; self.hue = hue }

    init?(encoded: String?) {
        guard let encoded, encoded.hasPrefix("preset:") else { return nil }
        let parts = encoded.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[2]) else { return nil }
        symbol = String(parts[1]); hue = h / 360
    }

    static let all: [AvatarPreset] = [
        .init(symbol: "hare.fill", hue: 0.58), .init(symbol: "tortoise.fill", hue: 0.36),
        .init(symbol: "bird.fill", hue: 0.08), .init(symbol: "cat.fill", hue: 0.78),
        .init(symbol: "dog.fill", hue: 0.11), .init(symbol: "fish.fill", hue: 0.52),
        .init(symbol: "leaf.fill", hue: 0.30), .init(symbol: "bolt.fill", hue: 0.14),
        .init(symbol: "moon.stars.fill", hue: 0.67), .init(symbol: "sun.max.fill", hue: 0.03),
        .init(symbol: "music.note", hue: 0.92), .init(symbol: "gamecontroller.fill", hue: 0.47),
    ]
}
