import AppKit
import SwiftUI

/// Slack's profile, in the right-hand pane beside the conversation. What the room already knows shows at once, and
/// the fetched profile replaces it quietly.
struct ProfilePane: View {
    let matrix: MatrixService
    let people: PeopleService
    let userID: String
    var fallback: ChatUser? = nil
    var onOpenConversation: (String) -> Void
    var onEditProfile: () -> Void
    var onClose: () -> Void
    @State private var shown = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let person = ShownProfile(people: people, userID: userID, fallback: fallback, me: matrix.user)
        let own = userID == matrix.user?.id
        let colors = appearance.colors
        VStack(spacing: 0) {
            PaneHeader(title: "Profile", closeLabel: "Close profile", onClose: onClose)
            ScrollView {
                // A contact card, as Contacts lays one out: the photo, name and status centered over the actions,
                // then the details in a grouped box.
                VStack(spacing: m.sp20) {
                    VStack(spacing: m.sp8) {
                        AvatarView(name: person.name, size: m.contactPhoto, matrix: matrix, source: person.avatarURL)
                            .padding(.bottom, m.sp4)
                        HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                            Text(person.name).font(m.font(.title1, .bold)).foregroundStyle(colors.textPrimary)
                                .textSelection(.enabled)
                            if own { TagLabel(text: "You") }
                        }.multilineTextAlignment(.center)
                        // Where Slack shows a title; Matrix has a status instead.
                        if let status = person.status {
                            Text(status).font(m.font(.reading)).foregroundStyle(colors.textSecondary)
                        }
                        if person.inCall {
                            Label {
                                Text("In a call")
                            } icon: {
                                Image(systemName: "video.fill").foregroundStyle(colors.presenceActive)
                            }.font(m.font(.reading)).foregroundStyle(colors.textSecondary)
                        }
                    }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    ProfileActions(
                        matrix: matrix, userID: userID, own: own, onOpen: onOpenConversation, onEdit: onEditProfile
                    )
                    // A failed Message belongs to the person it was for, not the next profile opened in the pane.
                    .id(userID)
                    VStack(alignment: .leading, spacing: m.sp2) {
                        Text("Matrix ID").font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                        Text(userID).font(m.font(.reading)).foregroundStyle(colors.textPrimary).lineLimit(1)
                            .truncationMode(.middle).textSelection(.enabled)
                    }
                    .padding(.horizontal, m.sp12).padding(.vertical, m(10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.sunken, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                }.padding(.horizontal, m.sp20).padding(.vertical, m.sp24)
            }
        }
        .foregroundStyle(colors.textBody).background(colors.canvas)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(Motion.pane) { shown = true } }
        .task(id: userID) { await people.loadProfile(userID: userID, fallback: fallback) }
    }
}

/// The name, photo and status to show: the fetched profile once it is in, the room's member until then. Your own name
/// and photo come from your account, so an edit shows at once.
struct ShownProfile {
    let name: String
    let avatarURL: String?
    let status: String?
    let inCall: Bool

    @MainActor init(people: PeopleService, userID: String, fallback: ChatUser?, me: ChatUser?) {
        let profile = people.profile?.id == userID ? people.profile : nil
        let known = fallback?.id == userID ? fallback : nil
        if let me, me.id == userID {
            name = me.name
            avatarURL = me.avatarURL
        } else {
            name = profile?.name ?? known?.name ?? userID
            avatarURL = profile?.avatarURL ?? known?.avatarURL
        }
        status = people.statusSupported ? profile?.status : nil
        inCall = profile?.inCall ?? false
    }
}

/// Slack's row of outlined buttons: Message for someone else, Edit profile for you, then ⋮. Message opens or creates
/// the direct message; its spinner waits like every other, and a failure shows under the row.
private struct ProfileActions: View {
    @Environment(Toasts.self) private var toasts: Toasts?
    let matrix: MatrixService
    let userID: String
    let own: Bool
    let onOpen: (String) -> Void
    let onEdit: () -> Void
    @State private var request: UUID?
    @State private var error: String?
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        VStack(spacing: m.sp8) {
            HStack(spacing: m.sp8) {
                if own {
                    Button("Edit profile", action: onEdit).buttonStyle(.secondary)
                } else {
                    Button(action: open) {
                        HStack(spacing: m.sp8) {
                            // The spinner takes the icon's place, so the row never shifts.
                            ZStack {
                                Image(systemName: "bubble.left").opacity(request == nil ? 1 : 0)
                                if request != nil { DelayedProgress() }
                            }
                            Text("Message")
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(request != nil || matrix.isPreview || (try? PeopleMapping.validatedID(userID)) == nil)
                }
                Button(action: showMenu) {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).accessibilityLabel("More actions")
                }.buttonStyle(.secondaryIcon).help("More actions")
            }.controlSize(.large)
            if let error {
                Text(error).font(m.font(.subheadline)).foregroundStyle(appearance.colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func open() {
        let id = UUID()
        let account = matrix.user?.id
        let target = userID
        request = id
        error = nil
        Task { @MainActor in
            do {
                let roomID = try await matrix.createDM(userID: target)
                guard request == id, matrix.user?.id == account else { return }
                request = nil
                onOpen(roomID)
            } catch {
                guard request == id, matrix.user?.id == account else { return }
                self.error = MatrixService.safeError(error)
                request = nil
            }
        }
    }

    /// A native menu, as everywhere.
    private func showMenu() {
        let copy = { [toasts] (text: String, confirmation: String) in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            toasts?.show(confirmation)
        }
        let commands = [
            MessageMenuCommand(id: "copy-id", title: "Copy member ID") { [userID] in copy(userID, "Member ID copied") },
            MessageMenuCommand(id: "copy-link", title: "Copy link to profile") { [userID] in
                copy(MatrixID.permalink(userID), "Link copied")
            },
        ]
        NativeMessageMenu.make(commands: commands).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
