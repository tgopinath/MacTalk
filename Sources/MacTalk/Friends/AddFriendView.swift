import MacTalkCore
import SwiftUI

struct AddFriendView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 44, height: 44)
                    Image(systemName: "person.badge.plus").font(.title2).foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a friend").font(.title2.weight(.semibold))
                    Text("They'll get an invitation. You can call each other once they accept.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("friend@example.com", text: $email)
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .focused($focused).onSubmit(send)
                .onChange(of: email) { _, _ in error = nil; result = nil }
            if let result { Banner(kind: .info, text: result) }
            if let error { Banner(kind: .error, text: error) }
            Spacer(minLength: 0)
            HStack {
                Text("Your email stays private: only people you invite can see it.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(action: send) {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text("Send Invitation")
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!EmailValidator.isValid(email) || busy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400, height: 300)
        .onAppear { focused = true }
    }

    private func send() {
        guard EmailValidator.isValid(email), !busy, let friends = model.friends else {
            error = MacTalkError.invalidEmail.errorDescription
            return
        }
        busy = true; error = nil; result = nil
        Task {
            defer { busy = false }
            do {
                result = try await friends.invite(email: email)
                email = ""
            } catch {
                self.error = (error as? MacTalkError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
