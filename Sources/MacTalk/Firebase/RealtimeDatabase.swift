import Foundation
import MacTalkCore
import OSLog

let dbLog = Logger(subsystem: "app.mactalk", category: "database")

/// Firebase Realtime Database over REST + Server-Sent Events.
/// Every request carries the user's Firebase ID token; database.rules.json decides access.
@MainActor
final class RealtimeDatabase {
    /// `{".sv": "timestamp"}`: replaced with the server's clock on write.
    static let serverTimestamp: [String: String] = [".sv": "timestamp"]
    static let root = "mactalk"

    private let baseURL: URL
    private let auth: FirebaseAuthClient

    init(baseURL: URL, auth: FirebaseAuthClient) {
        self.baseURL = baseURL
        self.auth = auth
    }

    private func url(_ path: String, query: [URLQueryItem] = []) async throws -> URL {
        let token = try await auth.idToken()
        var components = URLComponents(url: baseURL.appendingPathComponent("\(Self.root)/\(path).json"), resolvingAgainstBaseURL: false)!
        components.queryItems = query + [URLQueryItem(name: "auth", value: token)]
        return components.url!
    }

    // MARK: Reads

    func getJSON(_ path: String) async throws -> Any? {
        let data = try await send(method: "GET", path: path, body: nil)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as Any?
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T? {
        let data = try await send(method: "GET", path: path, body: nil)
        if data == Data("null".utf8) { return nil }
        return try JSONDecoder.firebase.decode(T.self, from: data)
    }

    // MARK: Writes

    /// Multi-path atomic update relative to the MacTalk root (`["a/b": value, "c": NSNull()]`).
    func update(_ values: [String: Any]) async throws {
        _ = try await send(method: "PATCH", path: "", body: values)
    }

    func set(_ path: String, _ value: Any) async throws {
        _ = try await send(method: "PUT", path: path, body: value)
    }

    func delete(_ path: String) async throws {
        _ = try await send(method: "DELETE", path: path, body: nil)
    }

    /// Appends with a chronologically ordered push key and returns it.
    @discardableResult
    func push(_ path: String, _ value: Any) async throws -> String {
        let data = try await send(method: "POST", path: path, body: value)
        struct Key: Decodable { let name: String }
        return try JSONDecoder().decode(Key.self, from: data).name
    }

    private func send(method: String, path: String, body: Any?, retried: Bool = false) async throws -> Data {
        var request = URLRequest(url: try await url(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw MacTalkError.network }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried {
            _ = try await auth.idToken(forceRefresh: true)
            return try await send(method: method, path: path, body: body, retried: true)
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "HTTP \(status)"
            dbLog.error("\(method, privacy: .public) \(path, privacy: .public) failed: \(status) \(message, privacy: .public)"); Diagnostics.log("error: \(method) \(path) failed: \(status) \(message)")
            throw MacTalkError.fromServer(message: message)
        }
        return data
    }

    // MARK: Live streams

    /// Streams a node as a continuously updated JSON tree. Reconnects with back-off,
    /// and refreshes the ID token when the server revokes it (tokens last one hour).
    func observe(_ path: String) -> AsyncStream<JSONSnapshot> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                var backoff = Backoff(base: 1, cap: 30)
                var tree: Any? = nil
                var refreshedAfterDenial = false
                while !Task.isCancelled {
                    guard let self else { break }
                    do {
                        var request = URLRequest(url: try await self.url(path))
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.timeoutInterval = 90 // the server sends keep-alives every 30 s
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 {
                            // One token refresh; a second 401 means the rules deny access, so back off.
                            if refreshedAfterDenial { throw MacTalkError.permissionDenied }
                            refreshedAfterDenial = true
                            _ = try await self.auth.idToken(forceRefresh: true)
                            continue
                        }
                        guard status == 200 else { throw MacTalkError.fromServer(message: "HTTP \(status)") }
                        refreshedAfterDenial = false
                        backoff.reset()
                        dbLog.info("stream \(path, privacy: .public) connected"); Diagnostics.log("info: stream \(path) connected")
                        var event = ""
                        for try await line in bytes.lines {
                            if line.hasPrefix("event:") {
                                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                                switch event {
                                case "put", "patch":
                                    guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                                          let at = object["path"] as? String else { continue }
                                    tree = JSONTree.apply(tree, at: at, data: object["data"], merge: event == "patch")
                                    continuation.yield(JSONSnapshot(value: tree))
                                case "auth_revoked":
                                    _ = try? await self.auth.idToken(forceRefresh: true)
                                    throw CancellationError()
                                case "cancel":
                                    throw MacTalkError.permissionDenied
                                default:
                                    break
                                }
                            }
                        }
                    } catch is CancellationError where !Task.isCancelled {
                        continue // reconnect with the fresh token
                    } catch {
                        if Task.isCancelled { break }
                        dbLog.error("stream \(path, privacy: .public) dropped: \(String(describing: error), privacy: .public)"); Diagnostics.log("error: stream \(path) dropped: \(String(describing: error))")
                    }
                    try? await Task.sleep(for: .seconds(backoff.nextDelay()))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Applies Realtime Database stream events to a local JSON tree.
enum JSONTree {
    static func apply(_ tree: Any?, at path: String, data: Any?, merge: Bool) -> Any? {
        let parts = path.split(separator: "/").map(String.init)
        return set(tree, parts[...], data, merge: merge)
    }

    private static func set(_ node: Any?, _ parts: ArraySlice<String>, _ data: Any?, merge: Bool) -> Any? {
        guard let head = parts.first else {
            if merge, var dict = node as? [String: Any], let patch = data as? [String: Any] {
                for (k, v) in patch {
                    if v is NSNull { dict[k] = nil } else { dict[k] = v }
                }
                return dict.isEmpty ? nil : dict
            }
            return data is NSNull ? nil : data
        }
        var dict = node as? [String: Any] ?? [:]
        dict[head] = set(dict[head], parts.dropFirst(), data, merge: merge)
        return dict.isEmpty ? nil : dict
    }

    static func decode<T: Decodable>(_ value: Any?, as: T.Type = T.self) -> T? {
        guard let value, !(value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder.firebase.decode(T.self, from: data)
    }
}

/// A JSON tree from the database (plain Foundation objects, never mutated after creation).
struct JSONSnapshot: @unchecked Sendable {
    let value: Any?
}
