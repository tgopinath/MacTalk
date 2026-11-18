import AppKit
import MacTalkCore
import SwiftUI

@main
struct MacTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        @Bindable var settings = delegate.model.settings
        MenuBarExtra(isInserted: $settings.showMenuBarIcon) {
            PopoverView()
                .environment(delegate.model)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: delegate.model.menuBarState))
                .accessibilityLabel(delegate.model.menuBarState.accessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), index + 1 < CommandLine.arguments.count {
            PreviewRenderer.renderAll(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            exit(0)
        }
        #endif
        // Menu bar app: no Dock icon (also set via LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            model.launch()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Task { await model.auth?.handleOpenURL(url) } }
    }

    /// Closing the last window (onboarding, settings…) never quits MacTalk.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Double-clicking MacTalk in Finder while it runs: bring back the menu bar icon if hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.settings.showMenuBarIcon {
            model.windows.showSettings(model: model)
        } else {
            MenuBarPopover.open()
        }
        return false
    }

    /// Quit from the menu: end any call and mark the user offline before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.backend != nil else { return .terminateNow }
        Task { @MainActor in
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
