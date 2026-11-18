import AppKit
import MacTalkCore
import SwiftUI

/// Circular avatar: uploaded photo, built-in preset, or initials.
struct AvatarView: View {
    let name: String
    let avatarURL: String?
    var size: CGFloat = 32
    var presence: PresenceStatus?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            if let presence {
                PresenceDot(status: presence, size: max(8, size * 0.3))
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityLabel(Text(name))
    }

    @ViewBuilder private var content: some View {
        if let preset = AvatarPreset(encoded: avatarURL) {
            PresetAvatar(preset: preset, size: size)
        } else if let avatarURL, let url = URL(string: avatarURL), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { initials }
            }
        } else {
            initials
        }
    }

    private var initials: some View {
        let hue = Double(abs(name.hashValue % 360)) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.85),
                                    Color(hue: hue, saturation: 0.6, brightness: 0.65)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(Initials.of(name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

struct PresetAvatar: View {
    let preset: AvatarPreset
    let size: CGFloat
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: preset.hue, saturation: 0.5, brightness: 0.95),
                                    Color(hue: preset.hue, saturation: 0.7, brightness: 0.7)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: preset.symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct PresenceDot: View {
    let status: PresenceStatus
    var size: CGFloat = 9
    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: max(1.5, size * 0.18)))
            .help(status.label)
    }
}

extension PresenceStatus {
    var color: Color {
        switch self {
        case .online: .green
        case .busy: .red
        case .dnd: .purple
        case .inCall: .blue
        case .offline: .gray
        }
    }
}

/// Loads an avatar as NSImage (for notification attachments).
enum AvatarImageLoader {
    static func image(for avatarURL: String?) async -> NSImage? {
        guard let avatarURL, let url = URL(string: avatarURL), url.scheme?.hasPrefix("http") == true,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
