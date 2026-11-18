import SwiftUI

/// The MacTalk mark: a walkie-talkie with a blue body and an orange screen, drawn on a 24-pt grid.
struct AppMark: View {
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var scheme

    private var body_: Color { scheme == .dark ? Color(red: 80/255, green: 145/255, blue: 1) : Color(red: 56/255, green: 122/255, blue: 253/255) }
    private var screen: Color { scheme == .dark ? Color(red: 1, green: 155/255, blue: 55/255) : Color(red: 245/255, green: 135/255, blue: 30/255) }

    var body: some View {
        Canvas { ctx, canvasSize in
            let k = canvasSize.width / 24
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * k, y: y * k, width: w * k, height: h * k) }
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Path {
                var p = Path(); p.move(to: CGPoint(x: x1 * k, y: y1 * k)); p.addLine(to: CGPoint(x: x2 * k, y: y2 * k)); return p
            }
            let stroke = StrokeStyle(lineWidth: 2 * k, lineCap: .round)
            ctx.stroke(Path(roundedRect: r(6, 6, 12, 16), cornerRadius: 4 * k), with: .color(body_), style: stroke)
            ctx.stroke(line(7, 6, 7, 1.5), with: .color(body_), style: stroke)
            ctx.fill(Path(roundedRect: r(8.5, 9, 7, 5.5), cornerRadius: 1.2 * k), with: .color(screen))
            ctx.stroke(line(10.5, 18, 13.5, 18), with: .color(screen), style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Round call-control button (Accept / Decline / Mute / End).
struct RoundButton: View {
    let systemImage: String
    var tint: Color = .secondary
    var filled = true
    var size: CGFloat = 40
    var label: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(filled ? .white : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? tint : tint.opacity(hovering ? 0.22 : 0.14)))
                .brightness(filled && hovering ? 0.06 : 0)
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Expanding rings behind an avatar while a call rings.
struct RingingRings: View {
    var color: Color = .green
    var size: CGFloat
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 1.55 : 1)
                    .opacity(animate ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false).delay(Double(i) * 0.7), value: animate)
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { nsView.material = material }
}

struct Banner: View {
    enum Kind { case info, warning, error }
    let kind: Kind
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.link).font(.callout.weight(.medium))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.12)))
    }

    private var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .warning: "wifi.exclamationmark"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

struct SpeedDialBadge: View {
    let modifier: String
    let slot: Int
    var body: some View {
        Text("\(modifier)\(slot)")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary.opacity(0.6)))
            .help("Press \(modifier)\(slot) anywhere to call")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(isEnabled ? 1 : 0.4)))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}
