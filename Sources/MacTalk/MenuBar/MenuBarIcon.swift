import AppKit
import MacTalkCore

/// What the menu bar icon shows.
enum MenuBarState: Equatable {
    case online, busy, offline, ringing(frame: Int), inCall

    var dotColor: NSColor {
        switch self {
        case .online: .systemGreen
        case .busy: .systemRed
        case .offline: .systemGray
        case .ringing: .systemOrange
        case .inCall: .systemBlue
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .online: "MacTalk – Online"
        case .busy: "MacTalk – Busy"
        case .offline: "MacTalk – Offline"
        case .ringing: "MacTalk – Incoming call"
        case .inCall: "MacTalk – In a call"
        }
    }
}

enum MenuBarIcon {
    /// Draws the walkie-talkie glyph in the menu bar's text color plus a colored status dot.
    /// Uses a drawing handler so the glyph re-renders for light / dark menu bars.
    static func image(for state: MenuBarState) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolName: String = switch state {
            case .ringing(let frame): frame % 2 == 0 ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right"
            case .inCall: "waveform"
            default: "flipphone"
            }
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [.labelColor]))
            if let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - 6 - g.width) / 2, y: (rect.height - g.height) / 2, width: g.width, height: g.height))
            }
            let dot = NSRect(x: rect.width - 7.5, y: 1.5, width: 6.5, height: 6.5)
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            state.dotColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }
}
