#if DEBUG
import AppKit
import MacTalkCore
import SwiftUI

/// Debug-only: renders every main screen with sample data to PNGs for design review.
///   MacTalk.app/Contents/MacOS/MacTalk --render-previews /path/to/dir
@MainActor
enum PreviewRenderer {
    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = AppConfiguration(environment: .development, firebaseAPIKey: String(repeating: "p", count: 40),
                                      databaseURL: URL(string: "https://preview.invalid"), authPageURL: URL(string: "https://preview.invalid/auth/"))
        let me = UserProfile(id: "me", email: "gopi@example.com", displayName: "Gopinath", avatarURL: "preset:bird.fill:29",
                             manualStatus: .online, profileCompleted: true)
        let friends = [
            Friend(id: UUID().uuidString, email: "alex@example.com", displayName: "Alex Johnson", avatarURL: "preset:hare.fill:209", presenceStatus: .online, lastSeen: Date()),
            Friend(id: UUID().uuidString, email: "mia@example.com", displayName: "Mia Chen", presenceStatus: .inCall, lastSeen: Date()),
            Friend(id: UUID().uuidString, email: "sam@example.com", displayName: "Sam Rivera", avatarURL: "preset:leaf.fill:108", presenceStatus: .busy, lastSeen: Date()),
            Friend(id: UUID().uuidString, email: "priya@example.com", displayName: "Priya Nair", presenceStatus: .online, lastSeen: Date()),
            Friend(id: UUID().uuidString, email: "leo@example.com", displayName: "Leo Park", avatarURL: "preset:moon.stars.fill:241", presenceStatus: .offline, lastSeen: Date().addingTimeInterval(-3600)),
        ]
        let request = FriendRequest(direction: .incoming, status: .pending, otherID: "nora",
                                    otherEmail: "nora@example.com", otherDisplayName: "Nora Ito")

        for (suffix, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            let model = AppModel(configuration: config)
            RunLoop.main.run(until: Date().addingTimeInterval(1)) // let AuthService finish its initial-session check
            model.auth?.debugSetState(.signedIn(me))
            model.friends?.debugSet(friends: friends, requests: [request])

            render(PopoverView().environment(model), size: CGSize(width: 330, height: 520), appearance: appearance,
                   to: dir.appendingPathComponent("popover-\(suffix).png"), material: true)

            var incoming = CallManager.Session(callID: UUID().uuidString, direction: .incoming, peer: CallPeer(friend: friends[0]),
                                               machine: CallStateMachine(direction: .incoming))
            model.calls?.debugSet(incoming)
            render(IncomingCallView().environment(model), size: CGSize(width: 360, height: 104), appearance: appearance,
                   to: dir.appendingPathComponent("incoming-\(suffix).png"))

            var machine = CallStateMachine(direction: .outgoing)
            machine.transition(to: .ringing); machine.apply(serverStatus: .accepted); machine.transition(to: .connected)
            incoming = CallManager.Session(callID: UUID().uuidString, direction: .outgoing, peer: CallPeer(friend: friends[0]), machine: machine,
                                           connectedAt: Date().addingTimeInterval(-272), isMuted: false, quality: .good)
            model.calls?.debugSet(incoming)
            render(ActiveCallView().environment(model), size: CGSize(width: 300, height: 380), appearance: appearance,
                   to: dir.appendingPathComponent("active-call-\(suffix).png"))

            model.calls?.debugSet(nil)
            model.friends?.debugSet(friends: [], requests: [])
            render(PopoverView().environment(model), size: CGSize(width: 330, height: 330), appearance: appearance,
                   to: dir.appendingPathComponent("popover-empty-\(suffix).png"), material: true)
        }

        let model = AppModel(configuration: config)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        model.auth?.debugSetState(.signedOut)
        render(OnboardingView().environment(model), size: CGSize(width: 440, height: 560), appearance: NSAppearance(named: .aqua)!,
               to: dir.appendingPathComponent("welcome.png"))
        for (suffix, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            render(SignInStep().environment(model).padding(.horizontal, 40).padding(.vertical, 28).frame(height: 560),
                   size: CGSize(width: 440, height: 560), appearance: appearance,
                   to: dir.appendingPathComponent("sign-in-\(suffix).png"), material: true)
        }
        model.auth?.debugSetState(.needsProfile(me))
        render(OnboardingView().environment(model), size: CGSize(width: 440, height: 560), appearance: NSAppearance(named: .aqua)!,
               to: dir.appendingPathComponent("profile-setup.png"))
        model.auth?.debugSetState(.signedIn(me))
        model.friends?.debugSet(friends: friends, requests: [])
        render(AddFriendView().environment(model), size: CGSize(width: 400, height: 300), appearance: NSAppearance(named: .aqua)!,
               to: dir.appendingPathComponent("add-friend.png"))
        render(ManageFriendsView(initialTab: .friends).environment(model), size: CGSize(width: 520, height: 460),
               appearance: NSAppearance(named: .aqua)!, to: dir.appendingPathComponent("manage-friends.png"))
        render(SettingsView(initialTab: .shortcuts).environment(model), size: CGSize(width: 560, height: 480),
               appearance: NSAppearance(named: .aqua)!, to: dir.appendingPathComponent("settings-speed-dial.png"))
        render(PopoverView().environment(AppModel(configuration: AppConfiguration(environment: .development, firebaseAPIKey: nil, databaseURL: nil, authPageURL: nil))),
               size: CGSize(width: 330, height: 260), appearance: NSAppearance(named: .aqua)!,
               to: dir.appendingPathComponent("config-needed.png"), material: true)

        for state in [MenuBarState.online, .busy, .offline, .ringing(frame: 0), .inCall] {
            let image = MenuBarIcon.image(for: state)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 88, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: 22, height: 18)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 22, height: 18).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: 22, height: 18))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("menubar-\(state.accessibilityLabel.split(separator: " ").last!).png"))
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance, to url: URL, material: Bool = false) {
        let root = view
            .frame(width: size.width)
            .background(material ? AnyView(Color(nsColor: .windowBackgroundColor)) : AnyView(Color.clear))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let fitting = host.fittingSize
        let frame = NSRect(x: 0, y: 0, width: size.width, height: max(min(fitting.height, 900), 40))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = appearance.name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
