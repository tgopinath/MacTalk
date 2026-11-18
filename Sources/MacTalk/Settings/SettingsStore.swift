import AppKit
import Foundation
import MacTalkCore
import Observation
import ServiceManagement

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum IncomingAlertStyle: String, CaseIterable, Identifiable {
    case callWindow, systemNotification, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .callWindow: "MacTalk call alert (bottom-right)"
        case .systemNotification: "macOS notification banner"
        case .both: "Both"
        }
    }
}

enum NotificationPreview: String, CaseIterable, Identifiable {
    case nameAndPhoto, nameOnly, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nameAndPhoto: "Show name and photo"
        case .nameOnly: "Show name only"
        case .hidden: "Hide caller (“Someone is calling”)"
        }
    }
}

enum SpeedDialModifier: String, CaseIterable, Identifiable {
    case control, controlOption, controlCommand
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .control: "⌃"
        case .controlOption: "⌃⌥"
        case .controlCommand: "⌃⌘"
        }
    }
}

/// User preferences persisted in UserDefaults.
@MainActor @Observable
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            K.showMenuBarIcon: true, K.openAtStartup: false, K.autoGoOnline: true,
            K.notificationsEnabled: true, K.alertStyle: IncomingAlertStyle.callWindow.rawValue,
            K.ringtoneEnabled: true, K.ringtoneName: "Submarine", K.ringtoneVolume: 0.8,
            K.preview: NotificationPreview.nameAndPhoto.rawValue, K.appearance: AppearanceMode.system.rawValue,
            K.outputVolume: 1.0, K.speedDialEnabled: true, K.speedDialModifier: SpeedDialModifier.control.rawValue,
        ])
        showMenuBarIcon = defaults.bool(forKey: K.showMenuBarIcon)
        openAtStartup = defaults.bool(forKey: K.openAtStartup)
        autoGoOnline = defaults.bool(forKey: K.autoGoOnline)
        notificationsEnabled = defaults.bool(forKey: K.notificationsEnabled)
        alertStyle = IncomingAlertStyle(rawValue: defaults.string(forKey: K.alertStyle) ?? "") ?? .callWindow
        ringtoneEnabled = defaults.bool(forKey: K.ringtoneEnabled)
        ringtoneName = defaults.string(forKey: K.ringtoneName) ?? "Submarine"
        ringtoneVolume = defaults.double(forKey: K.ringtoneVolume)
        preview = NotificationPreview(rawValue: defaults.string(forKey: K.preview) ?? "") ?? .nameAndPhoto
        appearance = AppearanceMode(rawValue: defaults.string(forKey: K.appearance) ?? "") ?? .system
        inputDeviceUID = defaults.string(forKey: K.inputDevice)
        outputDeviceUID = defaults.string(forKey: K.outputDevice)
        outputVolume = defaults.double(forKey: K.outputVolume)
        speedDialEnabled = defaults.bool(forKey: K.speedDialEnabled)
        speedDialModifier = SpeedDialModifier(rawValue: defaults.string(forKey: K.speedDialModifier) ?? "") ?? .control
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private enum K {
        static let showMenuBarIcon = "showMenuBarIcon", openAtStartup = "openAtStartup", autoGoOnline = "autoGoOnline"
        static let notificationsEnabled = "notificationsEnabled", alertStyle = "alertStyle"
        static let ringtoneEnabled = "ringtoneEnabled", ringtoneName = "ringtoneName", ringtoneVolume = "ringtoneVolume"
        static let preview = "notificationPreview", appearance = "appearance"
        static let inputDevice = "inputDeviceUID", outputDevice = "outputDeviceUID", outputVolume = "outputVolume"
        static let speedDialEnabled = "speedDialEnabled", speedDialModifier = "speedDialModifier"
        static func speedDialOrder(_ user: UserID) -> String { "speedDialOrder.\(user)" }
    }

    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: K.showMenuBarIcon) } }
    var openAtStartup: Bool { didSet { defaults.set(openAtStartup, forKey: K.openAtStartup) } }
    /// "Start automatically": go online as soon as MacTalk launches (otherwise start in Do Not Disturb).
    var autoGoOnline: Bool { didSet { defaults.set(autoGoOnline, forKey: K.autoGoOnline) } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: K.notificationsEnabled) } }
    var alertStyle: IncomingAlertStyle { didSet { defaults.set(alertStyle.rawValue, forKey: K.alertStyle) } }
    var ringtoneEnabled: Bool { didSet { defaults.set(ringtoneEnabled, forKey: K.ringtoneEnabled) } }
    var ringtoneName: String { didSet { defaults.set(ringtoneName, forKey: K.ringtoneName) } }
    var ringtoneVolume: Double { didSet { defaults.set(ringtoneVolume, forKey: K.ringtoneVolume) } }
    var preview: NotificationPreview { didSet { defaults.set(preview.rawValue, forKey: K.preview) } }
    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: K.appearance); applyAppearance() }
    }
    var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: K.inputDevice) } }
    var outputDeviceUID: String? { didSet { defaults.set(outputDeviceUID, forKey: K.outputDevice) } }
    var outputVolume: Double { didSet { defaults.set(outputVolume, forKey: K.outputVolume) } }
    var speedDialEnabled: Bool { didSet { defaults.set(speedDialEnabled, forKey: K.speedDialEnabled) } }
    var speedDialModifier: SpeedDialModifier { didSet { defaults.set(speedDialModifier.rawValue, forKey: K.speedDialModifier) } }

    private(set) var launchAtLogin: Bool
    private(set) var launchAtLoginError: String?

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "macOS didn't allow this: \(error.localizedDescription). Move MacTalk to Applications and try again."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginError = "Approve MacTalk in System Settings › General › Login Items."
        }
    }

    func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func speedDial(for user: UserID) -> SpeedDial {
        SpeedDial(order: defaults.stringArray(forKey: K.speedDialOrder(user)) ?? [])
    }

    func save(_ speedDial: SpeedDial, for user: UserID) {
        defaults.set(speedDial.order, forKey: K.speedDialOrder(user))
    }
}
