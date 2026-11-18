import MacTalkCore
import SwiftUI

struct ManageFriendsView: View {
    enum Tab: String, CaseIterable { case friends = "Friends", invitations = "Invitations", blocked = "Blocked" }

    @Environment(AppModel.self) private var model
    @State var initialTab: Tab
    @State private var message: String?
    @State private var confirm: ConfirmAction?

    enum ConfirmAction: Identifiable {
        case remove(Friend), block(UUID, String)
        var id: String {
            switch self {
            case .remove(let f): "remove-\(f.id)"
            case .block(let id, _): "block-\(id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $initialTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(label(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 10)

            if let message { Banner(kind: .info, text: message).padding(.horizontal, 20).padding(.bottom, 6) }

            switch initialTab {
            case .friends: friendsList
            case .invitations: invitationsList
            case .blocked: blockedList
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .task { await model.friends?.refreshAll() }
        .alert(item: $confirm) { action in
            switch action {
            case .remove(let friend):
                Alert(title: Text("Remove \(friend.name)?"),
                      message: Text("You won't be able to call each other until one of you sends a new invitation."),
                      primaryButton: .destructive(Text("Remove")) { run { try await model.friends?.remove(friend.id) } },
                      secondaryButton: .cancel())
            case .block(let id, let name):
                Alert(title: Text("Block \(name)?"),
                      message: Text("They won't be able to call you or send you invitations. They won't be told."),
                      primaryButton: .destructive(Text("Block")) { run { try await model.friends?.block(id) } },
                      secondaryButton: .cancel())
            }
        }
    }

    private func label(_ tab: Tab) -> String {
        switch tab {
        case .invitations:
            let n = model.friends?.incomingRequests.count ?? 0
            return n > 0 ? "Invitations (\(n))" : "Invitations"
        default: return tab.rawValue
        }
    }

    // MARK: Friends (speed-dial order)

    private var friendsList: some View {
        let friends = model.orderedFriends
        return Group {
            if friends.isEmpty {
                ContentUnavailableView {
                    Label("No friends yet", systemImage: "person.2")
                } description: {
                    Text("Invite someone by email to start talking.")
                } actions: {
                    Button("Add Friend") { model.windows.showAddFriend(model: model) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.settings.speedDialEnabled
                         ? "Drag to reorder. Your first nine friends can be called from anywhere with \(model.settings.speedDialModifier.symbol)1–\(model.settings.speedDialModifier.symbol)9."
                         : "Drag to reorder your friends list.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                    List {
                        ForEach(friends) { friend in
                            HStack(spacing: 10) {
                                Text(model.slot(for: friend).map { "\(model.settings.speedDialModifier.symbol)\($0)" } ?? "")
                                    .font(.system(.callout, design: .rounded).weight(.medium))
                                    .foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                                AvatarView(name: friend.name, avatarURL: friend.avatarURL, size: 30, presence: friend.effectivePresence())
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(friend.name).font(.body.weight(.medium))
                                    Text(friend.email).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button("Call") { Task { await model.calls?.call(friend) } }
                                        .disabled(!friend.effectivePresence().isCallable)
                                    Divider()
                                    Button("Remove Friend…") { confirm = .remove(friend) }
                                    Button("Block…", role: .destructive) { confirm = .block(friend.id, friend.name) }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }
                            .padding(.vertical, 3)
                        }
                        .onMove { model.moveFriends(from: $0, to: $1) }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: false))
                }
            }
        }
    }

    // MARK: Invitations

    private var invitationsList: some View {
        let incoming = model.friends?.incomingRequests ?? []
        let outgoing = model.friends?.outgoingRequests ?? []
        return Group {
            if incoming.isEmpty && outgoing.isEmpty {
                ContentUnavailableView("No invitations", systemImage: "envelope.open",
                                       description: Text("Invitations you send or receive show up here."))
            } else {
                List {
                    if !incoming.isEmpty {
                        Section("Received") {
                            ForEach(incoming) { request in
                                RequestRow(request: request) {
                                    Button("Block") { confirm = .block(request.otherID, request.otherName) }
                                    Button("Decline") { run { try await model.friends?.respond(request, accept: false) } }
                                    Button("Accept") { run { try await model.friends?.respond(request, accept: true) } }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                    if !outgoing.isEmpty {
                        Section("Sent") {
                            ForEach(outgoing) { request in
                                RequestRow(request: request) {
                                    if request.status == .pending {
                                        Button("Cancel") { run { try await model.friends?.cancel(request) } }
                                        Button("Resend") {
                                            run { message = try await model.friends?.resend(request) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Blocked

    private var blockedList: some View {
        let blocked = model.friends?.blocked ?? []
        return Group {
            if blocked.isEmpty {
                ContentUnavailableView("No blocked people", systemImage: "hand.raised",
                                       description: Text("People you block can't call you or send you invitations."))
            } else {
                List(blocked) { user in
                    HStack(spacing: 10) {
                        AvatarView(name: user.name, avatarURL: user.avatarURL, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(user.name).font(.body.weight(.medium))
                            Text(user.email).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unblock") { run { try await model.friends?.unblock(user.id) } }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch {
                message = (error as? MacTalkError)?.errorDescription ?? Backend.map(error).errorDescription
            }
        }
    }
}

private struct RequestRow<Actions: View>: View {
    let request: FriendRequest
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: request.otherName, avatarURL: request.otherAvatarURL, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.otherName).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(request.displayState)
                        .foregroundStyle(request.status == .declined ? .red : .secondary)
                    Text("· \(request.updatedAt.relativeShort)").foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
            Spacer()
            HStack(spacing: 6) { actions() }.controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}
