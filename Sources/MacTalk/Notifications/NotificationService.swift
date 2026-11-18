import AppKit
import Foundation
import MacTalkCore
import Observation
@preconcurrency import UserNotifications

/// macOS notifications: incoming-call banners with Accept/Decline actions, missed calls
/// and friend invitations. MacTalk's own bottom-right call alert does not depend on this,
/// so calls still ring if notifications are denied.
@MainActor @Observable
final class NotificationService: NSObject {
    enum Action { case accept(UUID), decline(UUID), callBack(UUID), acceptFriend(UUID), openApp }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    var onAction: ((Action) -> Void)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter requires a real app bundle (not `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func configure() {
        guard let center else { return }
        center.delegate = self
        let accept = UNNotificationAction(identifier: "ACCEPT", title: "Accept", options: [.foreground])
        let decline = UNNotificationAction(identifier: "DECLINE", title: "Decline", options: [.destructive])
        let callBack = UNNotificationAction(identifier: "CALL_BACK", title: "Call Back", options: [])
        let acceptFriend = UNNotificationAction(identifier: "ACCEPT_FRIEND", title: "Accept", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "INCOMING_CALL", actions: [accept, decline], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "MISSED_CALL", actions: [callBack], intentIdentifiers: []),
            UNNotificationCategory(identifier: "FRIEND_REQUEST", actions: [acceptFriend], intentIdentifiers: []),
        ])
        Task { await refreshAuthorization() }
    }

    func requestAuthorization() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        guard let center else { return }
        authorization = await center.notificationSettings().authorizationStatus
    }

    var isDenied: Bool { authorization == .denied }

    func showIncomingCall(callID: UUID, callerName: String, preview: NotificationPreview, avatar: NSImage?) {
        let content = UNMutableNotificationContent()
        content.title = preview == .hidden ? "Incoming call" : callerName
        content.body = preview == .hidden ? "Someone is calling you on MacTalk" : "Incoming voice call"
        content.categoryIdentifier = "INCOMING_CALL"
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["call_id": callID.uuidString]
        if preview == .nameAndPhoto, let avatar, let attachment = Self.attachment(avatar, id: callID) {
            content.attachments = [attachment]
        }
        post(id: "call-\(callID)", content: content)
    }

    func clearIncomingCall(_ callID: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: ["call-\(callID)"])
        center?.removePendingNotificationRequests(withIdentifiers: ["call-\(callID)"])
    }

    func showMissedCall(from peer: CallPeer, preview: NotificationPreview) {
        let content = UNMutableNotificationContent()
        content.title = "Missed call"
        content.body = preview == .hidden ? "You missed a MacTalk call" : "\(peer.name) tried to call you"
        content.categoryIdentifier = "MISSED_CALL"
        content.userInfo = ["peer_id": peer.id.uuidString]
        post(id: "missed-\(UUID())", content: content)
    }

    func showFriendRequest(_ request: FriendRequest) {
        let content = UNMutableNotificationContent()
        content.title = "New friend invitation"
        content.body = "\(request.otherName) wants to talk on MacTalk"
        content.categoryIdentifier = "FRIEND_REQUEST"
        content.userInfo = ["request_id": request.id.uuidString]
        post(id: "request-\(request.id)", content: content)
    }

    func showInfo(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(id: "info-\(UUID())", content: content)
    }

    private func post(id: String, content: UNMutableNotificationContent) {
        guard let center, authorization == .authorized || authorization == .provisional else { return }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private static func attachment(_ image: NSImage, id: UUID) -> UNNotificationAttachment? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactalk-avatar-\(id).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "avatar", url: url)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let callID = (info["call_id"] as? String).flatMap(UUID.init(uuidString:))
        let peerID = (info["peer_id"] as? String).flatMap(UUID.init(uuidString:))
        let requestID = (info["request_id"] as? String).flatMap(UUID.init(uuidString:))
        let actionID = response.actionIdentifier
        completionHandler()
        Task { @MainActor in
            let action: Action = switch (actionID, callID, peerID, requestID) {
            case ("ACCEPT", let c?, _, _): .accept(c)
            case ("DECLINE", let c?, _, _), (UNNotificationDismissActionIdentifier, let c?, _, _): .decline(c)
            case ("CALL_BACK", _, let p?, _): .callBack(p)
            case ("ACCEPT_FRIEND", _, _, let r?): .acceptFriend(r)
            default: .openApp
            }
            self.onAction?(action)
        }
    }
}
