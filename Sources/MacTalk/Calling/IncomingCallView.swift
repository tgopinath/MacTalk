import MacTalkCore
import SwiftUI

/// Bottom-right incoming call alert.
struct IncomingCallView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.calls?.session
        let preview = model.settings.preview
        let name = preview == .hidden ? "Someone" : session?.peer.name ?? "Someone"
        HStack(spacing: 12) {
            ZStack {
                RingingRings(color: .green, size: 46)
                if preview == .nameAndPhoto {
                    AvatarView(name: name, avatarURL: session?.peer.avatarURL, size: 46)
                } else {
                    AvatarView(name: name, avatarURL: nil, size: 46)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text("INCOMING CALL").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.4)
                Text(name).font(.headline).lineLimit(1)
                if session?.micDenied == true {
                    Text("Microphone access is off").font(.caption).foregroundStyle(.red)
                } else {
                    Label("Incoming voice call", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative)
                }
            }
            Spacer(minLength: 4)
            if session?.micDenied == true {
                VStack(spacing: 6) {
                    Button("Open Settings") { MicrophonePermission.openSystemSettings() }.controlSize(.small)
                    Button("Decline") { Task { await model.calls?.decline() } }.controlSize(.small)
                }
            } else {
                HStack(spacing: 10) {
                    RoundButton(systemImage: "phone.down.fill", tint: .red, size: 38, label: "Decline") {
                        Task { await model.calls?.decline() }
                    }
                    .keyboardShortcut(.cancelAction)
                    RoundButton(systemImage: "phone.fill", tint: .green, size: 38, label: "Accept") {
                        Task { await model.calls?.accept() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 360, height: 104)
        .background(WindowDragArea())
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Incoming call from \(name)")
    }
}
