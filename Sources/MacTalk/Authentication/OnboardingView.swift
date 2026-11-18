import AppKit
import MacTalkCore
import SwiftUI

/// Welcome → email → 6-digit code → profile (name, avatar, availability).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var started = false

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .windowBackground).ignoresSafeArea()
            Group {
                switch model.auth?.state {
                case .needsProfile(let profile): ProfileStep(profile: profile)
                case .signedIn: DoneStep()
                case .loading: ProgressView()
                default: started ? AnyView(SignInStep()) : AnyView(WelcomeStep { started = true })
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: model.auth?.state)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: started)
        .frame(width: 440, height: 560)
    }
}

private struct WelcomeStep: View {
    let next: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            AppMark(size: 96)
            VStack(spacing: 6) {
                Text("Welcome to MacTalk").font(.largeTitle.weight(.bold))
                Text("A walkie-talkie for your Mac. Call friends from the menu bar with one click.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                Feature(icon: "menubar.rectangle", title: "Lives in your menu bar", text: "Always one click away, quiet in the background.")
                Feature(icon: "person.2.badge.key", title: "Friends only", text: "Only people you accept can ever call you.")
                Feature(icon: "keyboard", title: "Speed dial", text: "Press ⌃1–⌃9 to call your top friends from anywhere.")
                Feature(icon: "lock.shield", title: "Private by design", text: "Encrypted peer-to-peer audio. Mic is off until you answer.")
            }
            .padding(.top, 6)
            Spacer()
            Button("Get Started", action: next).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }
}

private struct Feature: View {
    let icon: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).font(.callout)
            }
        }
    }
}

struct SignInStep: View {
    @Environment(AppModel.self) private var model
    @State private var waiting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 40)).foregroundStyle(Color.accentColor)
            Text("Sign in to MacTalk").font(.title.weight(.bold))
            Text("Use your Google account. New here? Signing in creates your MacTalk account.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = model.auth?.notice { Banner(kind: .info, text: notice) }
            GoogleSignInButton(busy: waiting) { signIn() }
            if waiting {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "safari").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Finish signing in with Google in your browser. MacTalk opens again when you're done.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Cancel") { model.auth?.cancelSignIn() }.buttonStyle(.link).font(.callout)
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Spacer()
            Text("Friends add you with the email of this Google account. MacTalk only sees your name, email and profile photo.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signIn() {
        waiting = true; error = nil
        Task {
            defer { waiting = false }
            do { try await model.auth?.signInWithGoogle() } catch MacTalkError.signInCancelled {
            } catch {
                self.error = (error as? MacTalkError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct ProfileStep: View {
    @Environment(AppModel.self) private var model
    let profile: UserProfile
    @State private var name = ""
    @State private var avatar: AvatarChoice = .preset(AvatarPreset.all[0])
    @State private var status: ManualStatus = .online
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create your profile").font(.title.weight(.bold))
            Text("This is how friends will see you.").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                AvatarPreview(choice: avatar, name: name.isEmpty ? profile.email : name, size: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display name").font(.caption).foregroundStyle(.secondary)
                    TextField("Your name", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
                }
            }
            AvatarPicker(choice: $avatar, googlePhoto: model.auth?.googlePhotoURL)
            VStack(alignment: .leading, spacing: 6) {
                Text("Availability").font(.caption).foregroundStyle(.secondary)
                Picker("Availability", selection: $status) {
                    ForEach(ManualStatus.allCases, id: \.self) { Text($0.presence.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Spacer()
            Button(action: save) {
                if busy { ProgressView().controlSize(.small).tint(.white) } else { Text("Continue") }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(name.nonEmpty == nil || busy).keyboardShortcut(.defaultAction)
        }
        .onAppear {
            name = profile.displayName ?? ""
            if let url = profile.avatarURL ?? model.auth?.googlePhotoURL {
                avatar = AvatarPreset(encoded: url).map(AvatarChoice.preset) ?? .existing(url)
            }
            status = profile.manualStatus
        }
    }

    private func save() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await model.auth?.completeProfile(displayName: name, avatar: avatar, status: status) } catch {
                self.error = (error as? MacTalkError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct AvatarPreview: View {
    let choice: AvatarChoice
    let name: String
    let size: CGFloat
    var body: some View {
        switch choice {
        case .preset(let p): PresetAvatar(preset: p, size: size)
        case .existing(let url): AvatarView(name: name, avatarURL: url, size: size)
        }
    }
}

struct AvatarPicker: View {
    @Binding var choice: AvatarChoice
    var googlePhoto: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Avatar").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 7), alignment: .leading, spacing: 8) {
                if let googlePhoto {
                    Button { choice = .existing(googlePhoto) } label: {
                        AvatarView(name: "Google photo", avatarURL: googlePhoto, size: 36)
                            .overlay(Circle().strokeBorder(choice == .existing(googlePhoto) ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                    }
                    .buttonStyle(.plain).help("Your Google photo")
                }
                ForEach(AvatarPreset.all) { preset in
                    Button { choice = .preset(preset) } label: {
                        PresetAvatar(preset: preset, size: 36)
                            .overlay(Circle().strokeBorder(choice == .preset(preset) ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
            Text("You're all set").font(.title.weight(.bold))
            Text("MacTalk is in your menu bar.").foregroundStyle(.secondary)
        }
    }
}

/// "Continue with Google" in Google's light button style (white, grey border, multicolour G).
struct GoogleSignInButton: View {
    let busy: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) } else { GoogleG().frame(width: 18, height: 18) }
                Text("Continue with Google").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(scheme == .dark ? Color(white: 0.89) : Color(red: 0.12, green: 0.12, blue: 0.12))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(scheme == .dark ? Color(red: 0.07, green: 0.07, blue: 0.08) : .white))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(scheme == .dark ? Color(white: 0.56) : Color(red: 0.45, green: 0.47, blue: 0.46), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("Continue with Google")
    }
}

/// Google "G" mark drawn from four arcs and the crossbar.
private struct GoogleG: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let line = s * 0.2
            ZStack {
                arc(from: 0.03, to: 0.125, color: Color(red: 0.26, green: 0.52, blue: 0.96), s: s, line: line) // blue (right)
                arc(from: 0.62, to: 0.86, color: Color(red: 0.92, green: 0.26, blue: 0.21), s: s, line: line)  // red (top)
                arc(from: 0.40, to: 0.62, color: Color(red: 0.98, green: 0.74, blue: 0.02), s: s, line: line)  // yellow (left)
                arc(from: 0.125, to: 0.40, color: Color(red: 0.20, green: 0.66, blue: 0.33), s: s, line: line) // green (bottom)
                Rectangle().fill(Color(red: 0.26, green: 0.52, blue: 0.96))
                    .frame(width: s * 0.47, height: line)
                    .offset(x: s * 0.2)
            }
            .frame(width: s, height: s)
        }
    }

    private func arc(from: CGFloat, to: CGFloat, color: Color, s: CGFloat, line: CGFloat) -> some View {
        Circle().trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .butt))
            .frame(width: s - line, height: s - line)
    }
}
