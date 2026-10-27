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
        let person = ProfileDetails(people: people, userID: userID, fallback: fallback)
        let own = userID == matrix.user?.id
        let colors = appearance.colors
        VStack(spacing: 0) {
            HStack {
                Text("Profile").font(m.font(.title, .bold))
                Spacer()
                IconButton(symbol: "xmark", label: "Close profile", role: .body, action: onClose)
            }.padding(.horizontal, m.sp20).frame(height: m.paneHeader)
            Divider().overlay(colors.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: m.sp16) {
                        AvatarView(
                            name: person.name, size: m.profilePhoto, cornerRadius: m.radiusLarge, matrix: matrix,
                            source: person.avatarURL
                        ).frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: m.sp4) {
                            HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                                Text(person.name).font(m.font(.header, .bold)).foregroundStyle(colors.textPrimary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if own { TagLabel(text: "You") }
                            }
                            // Where Slack shows a title; Matrix has a status instead.
                            if let status = person.status {
                                Text(status).font(m.font(.title)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if person.inCall {
                            Label {
                                Text("In a call")
                            } icon: {
                                Image(systemName: "video.fill").foregroundStyle(colors.presenceActive)
                            }.font(m.font(.body))
                        }
                        ProfileActions(
                            matrix: matrix, userID: userID, own: own, onOpen: onOpenConversation, onEdit: onEditProfile)
                    }.padding(m.sp20)
                    Divider().overlay(colors.border)
                    VStack(alignment: .leading, spacing: m.sp16) {
                        Text("Contact information").font(m.font(.body, .bold)).foregroundStyle(colors.textPrimary)
                        HStack(spacing: m.sp12) {
                            Image(systemName: "at").font(m.font(.body)).foregroundStyle(colors.textSecondary)
                                .frame(width: m.iconTile, height: m.iconTile)
                                .background(colors.sunken, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: m.sp2) {
                                Text("Matrix ID").font(m.font(.secondary, .semibold))
                                    .foregroundStyle(colors.textSecondary)
                                Text(userID).font(m.font(.body)).foregroundStyle(colors.accent).lineLimit(1)
                                    .truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }.padding(m.sp20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(colors.textBody).background(colors.canvas)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(Motion.pane) { shown = true } }
        .task(id: userID) { await people.loadProfile(userID: userID, fallback: fallback) }
    }
}

/// The name, photo and status to show: the fetched profile once it is in, the room's member until then.
private struct ProfileDetails {
    let name: String
    let avatarURL: String?
    let status: String?
    let inCall: Bool

    @MainActor init(people: PeopleService, userID: String, fallback: ChatUser?) {
        let profile = people.profile?.id == userID ? people.profile : nil
        let known = fallback?.id == userID ? fallback : nil
        name = profile?.name ?? known?.name ?? userID
        avatarURL = profile?.avatarURL ?? known?.avatarURL
        status = people.statusSupported ? profile?.status : nil
        inCall = profile?.inCall ?? false
    }
}

/// Slack's row of outlined buttons: Message for someone else, Edit profile for you, then ⋮. Message opens or creates
/// the direct message; its spinner waits like every other, and a failure shows under the row.
private struct ProfileActions: View {
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
        VStack(alignment: .leading, spacing: m.sp8) {
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
                    .buttonStyle(.secondary)
                    .disabled(request != nil || matrix.isPreview || (try? PeopleMapping.validatedID(userID)) == nil)
                }
                Button(action: showMenu) {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).accessibilityLabel("More actions")
                }.buttonStyle(.secondaryIcon).help("More actions")
            }.controlSize(.large)
            if let error {
                Text(error).font(m.font(.meta)).foregroundStyle(appearance.colors.destructive)
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
        let copy = { (text: String) in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let commands = [
            MessageMenuCommand(id: "copy-id", title: "Copy member ID") { [userID] in copy(userID) },
            MessageMenuCommand(id: "copy-link", title: "Copy link to profile") { [userID] in
                copy(MatrixID.permalink(userID))
            },
        ]
        NativeMessageMenu.make(commands: commands).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
