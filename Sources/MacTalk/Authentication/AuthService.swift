import AppKit
import Foundation
import MacTalkCore
import Observation
import Supabase

@MainActor @Observable
final class AuthService {
    enum State: Equatable {
        case loading
        case signedOut
        case awaitingCode(email: String)
        case needsProfile(UserProfile)
        case signedIn(UserProfile)
    }

    private(set) var state: State = .loading {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    var notice: String?

    private let backend: Backend
    private var listener: Task<Void, Never>?
    private var wasSignedIn = false

    init(backend: Backend) {
        self.backend = backend
        listener = Task { [weak self] in
            for await (event, session) in backend.client.auth.authStateChanges {
                await self?.handle(event: event, session: session)
            }
        }
    }

    var profile: UserProfile? {
        switch state {
        case .signedIn(let p), .needsProfile(let p): p
        default: nil
        }
    }

    var userID: UUID? { profile?.id }

    private func handle(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
            guard let session, !session.isExpired || event != .initialSession else {
                if event == .initialSession {
                    // A stored but expired session: try one refresh before asking to sign in.
                    if (try? await backend.client.auth.refreshSession()) == nil { state = .signedOut }
                }
                return
            }
            if case .signedIn = state, event == .tokenRefreshed { return }
            await loadProfile(userID: session.user.id)
        case .signedOut:
            if wasSignedIn { notice = MacTalkError.sessionExpired.errorDescription }
            wasSignedIn = false
            state = .signedOut
        default:
            break
        }
    }

    func loadProfile(userID: UUID) async {
        do {
            let p: UserProfile = try await backend.client.from("users")
                .select().eq("id", value: userID).single().execute().value
            wasSignedIn = true
            state = p.profileCompleted ? .signedIn(p) : .needsProfile(p)
        } catch {
            // Profile row is created by a trigger; a brand new account may race it once.
            try? await Task.sleep(for: .seconds(1))
            if let p: UserProfile = try? await backend.client.from("users")
                .select().eq("id", value: userID).single().execute().value {
                wasSignedIn = true
                state = p.profileCompleted ? .signedIn(p) : .needsProfile(p)
            } else {
                notice = Backend.map(error).errorDescription
                state = .signedOut
            }
        }
    }

    func sendCode(to email: String) async throws {
        let normalized = EmailValidator.normalize(email)
        guard EmailValidator.isValid(normalized) else { throw MacTalkError.invalidEmail }
        do {
            try await backend.client.auth.signInWithOTP(email: normalized, shouldCreateUser: true)
            state = .awaitingCode(email: normalized)
        } catch {
            throw Backend.map(error)
        }
    }

    func verify(code: String) async throws {
        guard case .awaitingCode(let email) = state else { return }
        let token = code.filter(\.isNumber)
        guard token.count >= 6 else { throw MacTalkError.invalidCode }
        do {
            try await backend.client.auth.verifyOTP(email: email, token: token, type: .email)
            // authStateChanges(.signedIn) loads the profile.
        } catch {
            let mapped = Backend.map(error)
            if case .server = mapped { throw MacTalkError.invalidCode }
            throw mapped
        }
    }

    func useDifferentEmail() { state = .signedOut }

    /// Redirect registered in Info.plist (CFBundleURLTypes) and in Supabase › Auth › URL Configuration.
    static let oauthRedirect = URL(string: "mactalk://auth-callback")!

    /// Google sign-in through Supabase OAuth in a system web-auth sheet (shares Safari's Google login).
    /// Google accounts arrive with a verified email, so they can call straight away.
    func signInWithGoogle() async throws {
        do {
            try await backend.client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: Self.oauthRedirect,
                queryParams: [(name: "prompt", value: "select_account")]
            ) { session in
                session.prefersEphemeralWebBrowserSession = false
            }
            // authStateChanges(.signedIn) loads the profile.
        } catch let error as NSError where error.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && error.code == 1 {
            return // user closed the sheet
        } catch {
            let mapped = Backend.map(error)
            if case .server(let message) = mapped, message.localizedCaseInsensitiveContains("provider is not enabled") {
                throw MacTalkError.server("Google sign-in isn't turned on for this MacTalk server yet. Use your email instead.")
            }
            throw mapped
        }
    }

    /// Fallback for the mactalk:// callback arriving through the app delegate.
    func handleOpenURL(_ url: URL) async {
        guard url.scheme == Self.oauthRedirect.scheme else { return }
        _ = try? await backend.client.auth.session(from: url)
    }

    #if DEBUG
    func debugSetState(_ newState: State) { state = newState }
    #endif

    func completeProfile(displayName: String, avatar: AvatarChoice, status: ManualStatus) async throws {
        guard let current = profile else { throw MacTalkError.notAuthenticated }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count) else { throw MacTalkError.server("Choose a name between 1 and 40 characters.") }
        let avatarURL = try await resolve(avatar, userID: current.id)
        struct Update: Encodable { let display_name: String; let avatar_url: String?; let profile_completed: Bool }
        do {
            try await backend.client.from("users")
                .update(Update(display_name: name, avatar_url: avatarURL, profile_completed: true))
                .eq("id", value: current.id).execute()
            try await backend.rpcVoid("set_manual_status", ["p_status": .string(status.rawValue)])
        } catch {
            throw Backend.map(error)
        }
        await loadProfile(userID: current.id)
    }

    func updateProfile(displayName: String, avatar: AvatarChoice?) async throws {
        guard let current = profile else { return }
        try await completeProfile(displayName: displayName,
                                  avatar: avatar ?? .existing(current.avatarURL),
                                  status: current.manualStatus)
    }

    func setLocalStatus(_ status: ManualStatus) {
        guard case .signedIn(var p) = state else { return }
        p.manualStatus = status
        p.presenceStatus = status.presence
        state = .signedIn(p)
    }

    private func resolve(_ avatar: AvatarChoice, userID: UUID) async throws -> String? {
        switch avatar {
        case .existing(let url): return url
        case .preset(let preset): return preset.encoded
        case .image(let data):
            let path = "\(userID.uuidString.lowercased())/avatar-\(Int(Date().timeIntervalSince1970)).jpg"
            do {
                try await backend.client.storage.from("avatars")
                    .upload(path, data: data, options: FileOptions(cacheControl: "86400", contentType: "image/jpeg", upsert: true))
                return try backend.client.storage.from("avatars").getPublicURL(path: path).absoluteString
            } catch {
                throw MacTalkError.server("Couldn't upload your photo. \(Backend.map(error).errorDescription ?? "")")
            }
        }
    }

    func signOut() async {
        try? await backend.rpcVoid("go_offline")
        try? await backend.client.auth.signOut(scope: .local)
        wasSignedIn = false
        state = .signedOut
    }
}

enum AvatarChoice: Equatable {
    case existing(String?)
    case preset(AvatarPreset)
    case image(Data)
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

enum ImageProcessing {
    /// Center-crops and downsizes to a 256×256 JPEG for upload.
    static func avatarJPEG(from url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: crop) else { return nil }
        let size = 256
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
