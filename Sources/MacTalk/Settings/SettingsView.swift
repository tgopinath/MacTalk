import MacTalkCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", notifications = "Notifications", audio = "Audio"
        case shortcuts = "Speed Dial", privacy = "Privacy", appearance = "Appearance"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .notifications: "bell.badge"
            case .audio: "waveform"
            case .shortcuts: "keyboard"
            case .privacy: "hand.raised"
            case .appearance: "paintbrush"
            }
        }
    }

    @State var initialTab: Tab

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: Binding(get: { initialTab }, set: { if let t = $0 { initialTab = t } })) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(160)
        } detail: {
            Group {
                switch initialTab {
                case .general: GeneralSettings()
                case .notifications: NotificationSettings()
                case .audio: AudioSettings()
                case .shortcuts: SpeedDialSettings()
                case .privacy: PrivacySettings()
                case .appearance: AppearanceSettings()
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                if let error = settings.launchAtLoginError { Text(error).font(.caption).foregroundStyle(.orange) }
                Toggle("Go online automatically when MacTalk starts", isOn: $settings.autoGoOnline)
                Toggle("Open MacTalk at startup", isOn: $settings.openAtStartup)
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("The icon is hidden. Open MacTalk from Applications to bring this window back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Closing windows", value: "MacTalk keeps running in the menu bar")
                LabeledContent("Quit", value: "Ends calls, goes offline, stops receiving calls")
            } header: { Text("Background") } footer: {
                Text("MacTalk receives calls only while it's running. When it's quit or the Mac is asleep, friends see you as offline.")
            }
        }
    }
}

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        Form {
            if model.notifications.isDenied {
                Section {
                    Banner(kind: .warning, text: "Notifications are off for MacTalk in System Settings. Calls still ring with the MacTalk alert.",
                           actionTitle: "Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } else if model.notifications.authorization == .notDetermined {
                Section { Button("Allow Notifications…") { Task { await model.notifications.requestAuthorization() } } }
            }
            Section("Incoming calls") {
                Toggle("Incoming call notifications", isOn: $settings.notificationsEnabled)
                Picker("Alert style", selection: $settings.alertStyle) {
                    ForEach(IncomingAlertStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.notificationsEnabled)
                Picker("Preview", selection: $settings.preview) {
                    ForEach(NotificationPreview.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Ringtone") {
                Toggle("Play ringtone", isOn: $settings.ringtoneEnabled)
                HStack {
                    Picker("Sound", selection: $settings.ringtoneName) {
                        ForEach(Ringtone.available, id: \.self) { Text($0).tag($0) }
                    }
                    Button { Ringtone().preview(name: settings.ringtoneName, volume: settings.ringtoneVolume) } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless).help("Preview")
                }
                .disabled(!settings.ringtoneEnabled)
                LabeledContent("Volume") {
                    Slider(value: $settings.ringtoneVolume, in: 0...1)
                }
                .disabled(!settings.ringtoneEnabled)
            }
        }
        .task { await model.notifications.refreshAuthorization() }
    }
}

private struct AudioSettings: View {
    @Environment(AppModel.self) private var model
    @State private var meter = InputLevelMeter()
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var micState = MicrophonePermission.state

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(inputs) { Text($0.name).tag(Optional($0.uid)) }
                }
                Picker("Speaker", selection: $settings.outputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(outputs) { Text($0.name).tag(Optional($0.uid)) }
                }
            } footer: {
                Text("During a call MacTalk switches to these devices and restores your previous ones afterwards.")
            }
            Section("Levels") {
                LabeledContent("Microphone input") {
                    HStack {
                        LevelMeter(level: meter.level).frame(height: 8)
                        Button(meter.isRunning ? "Stop" : "Test") {
                            if meter.isRunning { meter.stop() } else {
                                Task { if await MicrophonePermission.ensure() { meter.start() }; micState = MicrophonePermission.state }
                            }
                        }
                        .disabled(micState == .denied)
                    }
                }
                LabeledContent("Call volume") { Slider(value: $settings.outputVolume, in: 0...1) }
            }
            if micState == .denied {
                Section {
                    Banner(kind: .error, text: MacTalkError.microphoneDenied.errorDescription ?? "",
                           actionTitle: "Open Settings") { MicrophonePermission.openSystemSettings() }
                }
            }
        }
        .onAppear {
            inputs = AudioDevices.list(.input)
            outputs = AudioDevices.list(.output)
            micState = MicrophonePermission.state
        }
        .onDisappear { meter.stop() }
    }
}

private struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

private struct SpeedDialSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Speed-dial shortcuts", isOn: $settings.speedDialEnabled)
                    .onChange(of: settings.speedDialEnabled) { _, _ in model.applyHotkeys() }
                Picker("Shortcut", selection: $settings.speedDialModifier) {
                    ForEach(SpeedDialModifier.allCases) { Text("\($0.symbol)1 … \($0.symbol)9").tag($0) }
                }
                .onChange(of: settings.speedDialModifier) { _, _ in model.applyHotkeys() }
                .disabled(!settings.speedDialEnabled)
                if !model.hotkeyConflicts.isEmpty {
                    Text("Another app already uses \(model.hotkeyConflicts.map { "\(settings.speedDialModifier.symbol)\($0)" }.joined(separator: ", ")). Pick a different shortcut.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Works anywhere, even when the popover is closed. Press the same shortcut again to hang up, or to answer when that friend is calling you. If ⌃1–⌃9 switch Desktops on your Mac, turn that off in System Settings › Keyboard › Keyboard Shortcuts › Mission Control, or choose another shortcut here.")
            }
            Section("Order") {
                let friends = Array(model.orderedFriends.prefix(9))
                if friends.isEmpty {
                    Text("Add friends to fill your speed dial.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                        HStack {
                            Text("\(settings.speedDialModifier.symbol)\(index + 1)").monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                            AvatarView(name: friend.name, avatarURL: friend.avatarURL, size: 22)
                            Text(friend.name)
                        }
                    }
                }
                Button("Reorder in Manage Friends…") { model.windows.showManageFriends(model: model) }
            }
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var editingName = ""
    @State private var avatar: AvatarChoice = .existing(nil)
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        Form {
            if let profile = model.auth?.profile {
                Section("Profile") {
                    HStack(spacing: 14) {
                        AvatarPreview(choice: avatar, name: profile.name, size: 52)
                        TextField("Display name", text: $editingName)
                    }
                    AvatarPicker(choice: $avatar)
                    HStack {
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Save Profile") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await model.auth?.updateProfile(displayName: editingName, avatar: avatar); message = "Saved" }
                                catch { message = (error as? MacTalkError)?.errorDescription ?? error.localizedDescription }
                            }
                        }
                        .disabled(saving || editingName.nonEmpty == nil)
                    }
                }
                .onAppear {
                    editingName = profile.displayName ?? ""
                    avatar = .existing(profile.avatarURL)
                }
                Section("Account security") {
                    LabeledContent("Email", value: profile.email)
                    LabeledContent("Sign-in", value: "One-time email code · session stored in Keychain")
                    Button("Sign Out") { Task { await model.signOut() } }
                }
            }
            Section("Blocked people") {
                let blocked = model.friends?.blocked ?? []
                if blocked.isEmpty { Text("Nobody is blocked.").foregroundStyle(.secondary) }
                ForEach(blocked) { user in
                    HStack {
                        AvatarView(name: user.name, avatarURL: user.avatarURL, size: 22)
                        Text(user.name)
                        Spacer()
                        Button("Unblock") { Task { try? await model.friends?.unblock(user.id) } }
                    }
                }
            }
            Section("Microphone") {
                LabeledContent("Access", value: micLabel)
                Button("Manage in System Settings…") { MicrophonePermission.openSystemSettings() }
                Text("MacTalk only uses the microphone after you start or accept a call. It's never on while a call is ringing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var micLabel: String {
        switch MicrophonePermission.state {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        }
    }
}

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                Text("Follow system").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.inline)
        }
    }
}
