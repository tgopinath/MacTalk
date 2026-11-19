import MacTalkCore
import SwiftUI

/// The compact window that opens from the menu bar icon.
struct PopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.backend == nil {
                ConfigurationNeededView()
            } else if case .signedIn(let profile) = model.auth?.state {
                SignedInPopover(profile: profile)
            } else {
                SignedOutPopover()
            }
        }
        .frame(width: 330)
    }
}

private struct SignedOutPopover: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            AppMark(size: 60).padding(.top, 22)
            VStack(spacing: 4) {
                Text("MacTalk").font(.title3.weight(.semibold))
                Text("Talk to your friends with one click.").foregroundStyle(.secondary)
            }
            if model.auth?.state == .loading {
                ProgressView().controlSize(.small)
            } else {
                Button("Sign In or Create Account") { model.windows.showOnboarding(model: model) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Divider()
            Button("Quit MacTalk") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
    }
}

private struct SignedInPopover: View {
    @Environment(AppModel.self) private var model
    let profile: UserProfile
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 8) {
                if !model.network.isOnline {
                    Banner(kind: .warning, text: "You're offline. MacTalk will reconnect automatically.")
                }
                if let toast = model.calls?.toast {
                    Banner(kind: .info, text: toast).transition(.opacity)
                }
                if let error = model.friends?.loadError, model.network.isOnline {
                    Banner(kind: .error, text: error == .network ? "Can't reach the MacTalk server right now." : (error.errorDescription ?? "Couldn't load friends."),
                           actionTitle: "Retry") {
                        Task { await model.friends?.refreshPresence() }
                    }
                }
                if let call = model.calls?.session, !call.phase.isTerminal {
                    ActiveCallStrip(session: call)
                }
                InvitationsSection()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .animation(.easeInOut(duration: 0.2), value: model.calls?.toast)

            FriendsSection(search: $search)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppMark(size: 28)
            Text("MacTalk").font(.headline)
            Spacer()
            Menu {
                Section(profile.name) {
                    ForEach(ManualStatus.allCases, id: \.self) { status in
                        Button {
                            model.setStatus(status)
                        } label: {
                            Label(status.presence.label, systemImage: profile.manualStatus == status ? "checkmark" : "circle.fill")
                        }
                    }
                }
                Divider()
                Button("Edit Profile…") { model.windows.showSettings(model: model, tab: .privacy) }
                Button("Sign Out") { Task { await model.signOut() } }
            } label: {
                HStack(spacing: 6) {
                    AvatarView(name: profile.name, avatarURL: profile.avatarURL, size: 24,
                               presence: model.network.isOnline ? profile.manualStatus.presence : .offline)
                    Text(model.network.isOnline ? profile.manualStatus.presence.label : "Offline")
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Add Friend", icon: "person.badge.plus") { model.windows.showAddFriend(model: model) }
            FooterButton(title: "Manage", icon: "person.2") { model.windows.showManageFriends(model: model) }
            FooterButton(title: "Settings", icon: "gearshape") { model.windows.showSettings(model: model) }
            FooterButton(title: "Quit", icon: "power") { NSApp.terminate(nil) }
        }
        .padding(6)
    }
}

private struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

private struct ActiveCallStrip: View {
    @Environment(AppModel.self) private var model
    let session: CallManager.Session
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").foregroundStyle(.blue).symbolEffect(.variableColor.iterative, isActive: session.phase == .connected)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.peer.name).font(.callout.weight(.medium))
                Text(session.phase.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show") { model.windows.showActiveCall(model: model) }.controlSize(.small)
            Button { Task { await model.calls?.endCall() } } label: {
                Image(systemName: "phone.down.fill")
            }
            .controlSize(.small).tint(.red).buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.blue.opacity(0.1)))
    }
}

private struct InvitationsSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let incoming = model.friends?.incomingRequests ?? []
        if !incoming.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Invitations").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(incoming) { request in
                    HStack(spacing: 8) {
                        AvatarView(name: request.otherName, avatarURL: request.otherAvatarURL, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(request.otherName).font(.callout.weight(.medium)).lineLimit(1)
                            Text("wants to be friends").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Decline") { respond(request, false) }.controlSize(.small)
                        Button("Accept") { respond(request, true) }.controlSize(.small).buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.08)))
        }
    }

    private func respond(_ request: FriendRequest, _ accept: Bool) {
        Task {
            do { try await model.friends?.respond(request, accept: accept) } catch {
                model.calls?.show(toast: Backend.map(error).errorDescription)
            }
        }
    }
}

private struct FriendsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var search: String

    var body: some View {
        let all = model.orderedFriends
        let filtered = search.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.email.localizedCaseInsensitiveContains(search)
        }
        VStack(spacing: 6) {
            if model.friends?.isLoading == true && all.isEmpty {
                ProgressView().controlSize(.small).padding(30)
            } else if all.isEmpty {
                EmptyFriendsView()
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search friends", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 12)

                if filtered.isEmpty {
                    Text("No friends match “\(search)”").font(.callout).foregroundStyle(.secondary).padding(20)
                } else {
                    ScrollView {
                        // Re-evaluate staleness every 30 s so quiet friends drop to offline.
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            LazyVStack(spacing: 1) {
                                ForEach(filtered) { friend in
                                    FriendRow(friend: friend, presence: friend.effectivePresence(now: context.date))
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .frame(height: min(CGFloat(filtered.count) * 50 + 8, 360)) // explicit height: a ScrollView collapses to 0 in MenuBarExtra
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct FriendRow: View {
    @Environment(AppModel.self) private var model
    let friend: Friend
    let presence: PresenceStatus
    @State private var hovering = false

    var body: some View {
        let session = model.calls?.session
        let inCallWithFriend = session.map { $0.peer.id == friend.id && !$0.phase.isTerminal } ?? false
        HStack(spacing: 10) {
            AvatarView(name: friend.name, avatarURL: friend.avatarURL, size: 34, presence: presence)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(friend.name).font(.body.weight(.medium)).lineLimit(1)
                    if let slot = model.slot(for: friend) {
                        SpeedDialBadge(modifier: model.settings.speedDialModifier.symbol, slot: slot)
                    }
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if inCallWithFriend {
                RoundButton(systemImage: "phone.down.fill", tint: .red, size: 30, label: "End call") {
                    Task { await model.calls?.endCall() }
                }
            } else {
                RoundButton(systemImage: "phone.fill", tint: .green, filled: presence.isCallable, size: 30,
                            label: presence.isCallable ? "Call \(friend.name)" : "\(friend.name) is \(presence.label.lowercased())") {
                    Task { await model.calls?.call(friend) }
                }
                .opacity(presence.isCallable ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { Task { await model.calls?.call(friend) } }
        .contextMenu {
            Button("Call") { Task { await model.calls?.call(friend) } }.disabled(!presence.isCallable)
            Button("Manage Friends…") { model.windows.showManageFriends(model: model) }
        }
    }

    private var statusText: String {
        switch presence {
        case .offline:
            if let lastSeen = friend.lastSeen { return "Offline · seen \(lastSeen.relativeShort)" }
            return "Offline"
        default: return presence.label
        }
    }
}

private struct EmptyFriendsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 64, height: 64)
                Image(systemName: "person.2.wave.2.fill").font(.system(size: 26)).foregroundStyle(Color.accentColor)
            }
            Text("No friends yet").font(.headline)
            Text("Invite someone by email. Once they accept, you can call them with one click.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Your First Friend") { model.windows.showAddFriend(model: model) }
                .buttonStyle(PrimaryButtonStyle()).frame(width: 200)
            if !(model.friends?.outgoingRequests.isEmpty ?? true) {
                Button("\(model.friends?.outgoingRequests.count ?? 0) invitation(s) waiting") {
                    model.windows.showManageFriends(model: model, tab: .invitations)
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }
}

struct ConfigurationNeededView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { AppMark(size: 34); Text("MacTalk").font(.headline) }
            Banner(kind: .error, text: MacTalkError.notConfigured.errorDescription ?? "")
            Text("1. Create the Realtime Database and deploy database.rules.json.\n2. Put the Firebase settings in Config/development.env.\n3. Rebuild with scripts/build-app.sh.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("See README.md for the full setup.").font(.caption).foregroundStyle(.tertiary)
            HStack { Spacer(); Button("Quit MacTalk") { NSApp.terminate(nil) } }
        }
        .padding(16)
    }
}
