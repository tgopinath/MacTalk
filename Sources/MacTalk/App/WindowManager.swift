import AppKit
import SwiftUI

/// Creates and reuses MacTalk's windows. Closing a window never quits the app.
@MainActor
final class WindowManager {
    enum ID: String { case onboarding, addFriend, manageFriends, settings, incomingCall, activeCall }

    private var windows: [ID: NSWindow] = [:]

    func isVisible(_ id: ID) -> Bool { windows[id]?.isVisible ?? false }

    func close(_ id: ID) {
        guard let window = windows[id] else { return }
        if id == .incomingCall || id == .activeCall {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { window.orderOut(nil); window.alphaValue = 1 } })
        } else {
            window.close()
        }
        windows[id] = nil
    }

    // MARK: Standard windows

    func showOnboarding(model: AppModel) {
        show(.onboarding, title: "Welcome to MacTalk", size: NSSize(width: 440, height: 560)) {
            OnboardingView().environment(model)
        }
    }

    func showAddFriend(model: AppModel) {
        show(.addFriend, title: "Add Friend", size: NSSize(width: 400, height: 300)) {
            AddFriendView().environment(model)
        }
    }

    func showManageFriends(model: AppModel, tab: ManageFriendsView.Tab = .friends) {
        show(.manageFriends, title: "Manage Friends", size: NSSize(width: 520, height: 520), resizable: true) {
            ManageFriendsView(initialTab: tab).environment(model)
        }
    }

    func showSettings(model: AppModel, tab: SettingsView.Tab = .general) {
        show(.settings, title: "MacTalk Settings", size: NSSize(width: 560, height: 480)) {
            SettingsView(initialTab: tab).environment(model)
        }
    }

    private func show<Content: View>(_ id: ID, title: String, size: NSSize, resizable: Bool = false,
                                     @ViewBuilder content: () -> Content) {
        MenuBarPopover.close()
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.insert(.resizable); style.insert(.miniaturizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.setContentSize(size)
        window.center()
        let observer = WindowCloseObserver { [weak self] in self?.windows[id] = nil }
        window.delegate = observer
        objc_setAssociatedObject(window, &WindowCloseObserver.key, observer, .OBJC_ASSOCIATION_RETAIN)
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Call panels (bottom-right, above full-screen apps, on every Space)

    func showIncomingCall(model: AppModel) {
        guard windows[.incomingCall] == nil else { return }
        let panel = makePanel(size: NSSize(width: 360, height: 104)) { IncomingCallView().environment(model) }
        windows[.incomingCall] = panel
        present(panel, slideIn: true)
    }

    func showActiveCall(model: AppModel) {
        guard windows[.activeCall] == nil else { return }
        let panel = makePanel(size: NSSize(width: 300, height: 380)) { ActiveCallView().environment(model) }
        panel.isMovableByWindowBackground = true
        windows[.activeCall] = panel
        present(panel, slideIn: false)
    }

    private func makePanel<Content: View>(size: NSSize, @ViewBuilder content: () -> Content) -> NSPanel {
        let panel = CallPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content())
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }

    private func present(_ panel: NSPanel, slideIn: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { panel.orderFrontRegardless(); return }
        let size = panel.frame.size
        let target = NSPoint(x: visible.maxX - size.width - 16, y: visible.minY + 16)
        if slideIn {
            panel.setFrameOrigin(NSPoint(x: visible.maxX + 8, y: target.y))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrameOrigin(target)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrameOrigin(target)
            panel.orderFrontRegardless()
        }
    }
}

/// Borderless panels can't become key by default; allow it so buttons get keyboard focus.
final class CallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var key = 0
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Opens / closes the MenuBarExtra window programmatically.
@MainActor
enum MenuBarPopover {
    static func open() {
        guard !isOpen else { return }
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = window.contentView?.firstSubview(of: NSStatusBarButton.self) {
                button.performClick(nil)
                return
            }
        }
    }

    static func close() {
        for window in NSApp.windows where window.className.contains("MenuBarExtraWindow") && window.isVisible {
            window.orderOut(nil)
        }
    }

    static var isOpen: Bool {
        NSApp.windows.contains { $0.className.contains("MenuBarExtraWindow") && $0.isVisible }
    }
}

extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for sub in subviews { if let match = sub.firstSubview(of: type) { return match } }
        return nil
    }
}
