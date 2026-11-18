import MacTalkCore
import SwiftUI

/// Floating call window: avatar, name, status, timer, quality, mute, audio devices, end.
struct ActiveCallView: View {
    @Environment(AppModel.self) private var model
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var showAudio = false

    var body: some View {
        let session = model.calls?.session
        VStack(spacing: 0) {
            HStack {
                AppMark(size: 20)
                Text("MacTalk").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let q = session?.quality, session?.phase == .connected { QualityBars(quality: q) }
            }
            .padding(.horizontal, 16).padding(.top, 14)

            Spacer(minLength: 8)

            if let session {
                ZStack {
                    if [.initiating, .ringing, .connecting, .accepted, .reconnecting].contains(session.phase) {
                        RingingRings(color: session.phase == .reconnecting ? .orange : .blue, size: 84)
                    }
                    AvatarView(name: session.peer.name, avatarURL: session.peer.avatarURL, size: 84)
                    if session.isMuted {
                        Image(systemName: "mic.slash.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(6).background(Circle().fill(.red)).offset(x: 30, y: 30)
                    }
                }
                .frame(height: 100)

                Text(session.peer.name).font(.title3.weight(.semibold)).padding(.top, 10).lineLimit(1)
                Text(statusText(session))
                    .font(.callout).foregroundStyle(session.phase == .failed ? .red : .secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)

                if let connectedAt = session.connectedAt, !session.phase.isTerminal {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(CallDurationFormatter.string(ctx.date.timeIntervalSince(connectedAt)))
                            .font(.system(size: 26, weight: .light, design: .rounded)).monospacedDigit()
                    }
                    .padding(.top, 6)
                }

                Spacer(minLength: 10)

                if session.micDenied {
                    VStack(spacing: 8) {
                        Text(MacTalkError.microphoneDenied.errorDescription ?? "").font(.caption)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Open Microphone Settings") { MicrophonePermission.openSystemSettings() }
                        Button("Close") { model.calls?.dismiss() }.buttonStyle(.link)
                    }
                    .padding(.horizontal, 18).padding(.bottom, 18)
                } else if session.phase.isTerminal {
                    Button("Close") { model.calls?.dismiss() }.controlSize(.large).padding(.bottom, 22)
                } else {
                    controls(session)
                }
            }
        }
        .frame(width: 300, height: 380)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .onAppear(perform: loadDevices)
    }

    private func statusText(_ s: CallManager.Session) -> String {
        if let detail = s.detail, s.phase.isTerminal || s.phase == .reconnecting { return detail }
        if s.phase == .connected { return s.isMuted ? "Connected · You're muted" : "Connected" }
        return s.phase.label
    }

    @ViewBuilder private func controls(_ session: CallManager.Session) -> some View {
        let mediaReady = session.phase.allowsMedia
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                VStack(spacing: 4) {
                    RoundButton(systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill",
                                tint: session.isMuted ? .red : .primary, filled: session.isMuted, size: 46,
                                label: session.isMuted ? "Unmute" : "Mute") { model.calls?.toggleMute() }
                        .disabled(!mediaReady)
                        .keyboardShortcut("m", modifiers: [])
                    Text(session.isMuted ? "Unmute" : "Mute").font(.caption2).foregroundStyle(.secondary)
                }
                .opacity(mediaReady ? 1 : 0.4)
                VStack(spacing: 4) {
                    RoundButton(systemImage: "speaker.wave.2.fill", tint: .primary, filled: false, size: 46, label: "Audio devices") {
                        loadDevices(); showAudio.toggle()
                    }
                    .popover(isPresented: $showAudio, arrowEdge: .bottom) { audioPopover }
                    Text("Speaker").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await model.calls?.endCall() }
            } label: {
                Label(session.phase == .ringing || session.phase == .initiating ? "Cancel" : "End Call", systemImage: "phone.down.fill")
                    .font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 160, height: 38)
                    .background(Capsule().fill(.red))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.bottom, 20)
    }

    private var audioPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Speaker", selection: Binding(
                get: { model.settings.outputDeviceUID ?? AudioDevices.defaultUID(.output) ?? "" },
                set: { model.calls?.switchOutput(to: $0); model.settings.outputDeviceUID = $0 })) {
                ForEach(outputs) { Text($0.name).tag($0.uid) }
            }
            Picker("Microphone", selection: Binding(
                get: { model.settings.inputDeviceUID ?? AudioDevices.defaultUID(.input) ?? "" },
                set: { model.calls?.switchInput(to: $0); model.settings.inputDeviceUID = $0 })) {
                ForEach(inputs) { Text($0.name).tag($0.uid) }
            }
            LabeledContent("Volume") {
                Slider(value: Binding(get: { model.settings.outputVolume }, set: { model.calls?.setOutputVolume($0) }), in: 0...1)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func loadDevices() {
        inputs = AudioDevices.list(.input)
        outputs = AudioDevices.list(.output)
    }
}

struct QualityBars: View {
    let quality: ConnectionQuality
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= quality.bars ? color : Color.primary.opacity(0.18))
                    .frame(width: 3, height: CGFloat(3 + i * 3))
            }
        }
        .help(quality.label)
        .accessibilityLabel(quality.label)
    }

    private var color: Color {
        switch quality {
        case .poor: .red
        case .fair: .orange
        default: .green
        }
    }
}
