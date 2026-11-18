import Foundation

/// Every failure the user can see, with human-friendly copy.
public enum MacTalkError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case notAuthenticated
    case sessionExpired
    case emailNotVerified
    case invalidEmail
    case invalidCode
    case rateLimited
    case notFriends
    case permissionDenied
    case signInCancelled
    case friendOffline(String)
    case friendBusy(String)
    case friendDND(String)
    case friendInCall(String)
    case alreadyInCall
    case crossedCall(CallID)
    case callExpired
    case callNotFound
    case microphoneDenied
    case notificationsDenied
    case network
    case webRTCFailed
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "MacTalk isn't connected to Firebase yet. Add the Firebase settings in Config/ and rebuild."
        case .notAuthenticated: "Please sign in to continue."
        case .sessionExpired: "Your session expired. Please sign in again."
        case .emailNotVerified: "Verify your email before making or receiving calls."
        case .invalidEmail: "That doesn't look like an email address."
        case .invalidCode: "That code didn't work. Check the latest email and try again."
        case .rateLimited: "You're doing that a bit too often. Wait a minute and try again."
        case .notFriends: "You can only call people who accepted your invitation."
        case .permissionDenied: "MacTalk's server didn't allow that. Check that you're still friends and try again."
        case .signInCancelled: "Sign-in was cancelled."
        case .friendOffline(let n): "\(n) is offline right now."
        case .friendBusy(let n): "\(n) is busy right now."
        case .friendDND(let n): "\(n) has Do Not Disturb on."
        case .friendInCall(let n): "\(n) is already in a call."
        case .alreadyInCall: "You're already in a call."
        case .crossedCall: "They're calling you right now."
        case .callExpired: "This call has already ended."
        case .callNotFound: "This call is no longer available."
        case .microphoneDenied: "MacTalk needs microphone access to talk. Turn it on in System Settings › Privacy & Security › Microphone."
        case .notificationsDenied: "Notifications are off for MacTalk. Incoming calls will still appear in the call window."
        case .network: "You're offline. MacTalk will reconnect automatically."
        case .webRTCFailed: "Couldn't connect the audio. Check your network and try again."
        case .server(let message): message
        }
    }

    /// Maps error codes raised by the SQL functions to typed errors.
    public static func fromServer(message: String, detail: String? = nil, peerName: String = "Your friend") -> MacTalkError {
        let code = message.lowercased()
        func has(_ s: String) -> Bool { code.contains(s) }
        if has("not_authenticated") || has("jwt expired") || has("invalid jwt") { return .sessionExpired }
        if has("email_not_verified") { return .emailNotVerified }
        if has("invalid_email") { return .invalidEmail }
        if has("rate_limited") || has("rate limit") { return .rateLimited }
        if has("not_friends") { return .notFriends }
        if has("friend_offline") { return .friendOffline(peerName) }
        if has("friend_dnd") { return .friendDND(peerName) }
        if has("friend_busy") { return .friendBusy(peerName) }
        if has("friend_in_call") { return .friendInCall(peerName) }
        if has("already_in_call") { return .alreadyInCall }
        if has("crossed_call"), let detail { return .crossedCall(detail) }
        if has("permission denied") || has("permission_denied") { return .permissionDenied }
        if has("token_expired") || has("invalid_refresh_token") || has("user_disabled") || has("user_not_found") { return .sessionExpired }
        if has("call_expired") || has("call_not_ringing") { return .callExpired }
        if has("call_not_found") { return .callNotFound }
        return .server(message)
    }
}

public enum EmailValidator {
    public static func isValid(_ email: String) -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.count <= 254, let at = e.firstIndex(of: "@") else { return false }
        let local = e[..<at], domain = e[e.index(after: at)...]
        return !local.isEmpty && !local.contains(" ") && domain.contains(".")
            && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("@") && !domain.contains(" ")
    }

    public static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum Initials {
    public static func of(_ name: String) -> String {
        let base = name.split(separator: "@").first.map(String.init) ?? name
        let parts = base.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        let letters = parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
