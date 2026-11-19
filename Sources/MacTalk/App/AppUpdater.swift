import AppKit
import Observation
import Sparkle

/// Automatic updates with Sparkle. MacTalk checks the signed appcast hourly, downloads new
/// versions in the background and installs them on its own, but never during a call:
/// if one is in progress, installation waits until it ends. Only updates signed with the
/// MacTalk EdDSA key (public half in Info.plist) are accepted.
@MainActor @Observable
final class AppUpdater: NSObject {
    /// True while MacTalk shouldn't restart (a call is ringing or connected).
    var isBusy: () -> Bool = { false }
    private(set) var pendingVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var waitTask: Task<Void, Never>?

    override init() {
        super.init()
        // Sparkle needs a real app bundle with a feed URL (not `swift run`).
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            controller?.updater.automaticallyChecksForUpdates = true
        }
    }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Installs a downloaded update as soon as no call is active.
    private func installWhenIdle(_ install: @escaping () -> Void) {
        pendingInstall = install
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isBusy() {
                    Diagnostics.log("updater: installing \(self.pendingVersion ?? "update") and relaunching")
                    self.pendingInstall?()
                    self.pendingInstall = nil
                    return
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let install = immediateInstallHandler
        MainActor.assumeIsolated {
            pendingVersion = version
            Diagnostics.log("updater: \(version) downloaded")
            installWhenIdle(install)
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Diagnostics.log("updater: \(error.localizedDescription)")
    }
}
