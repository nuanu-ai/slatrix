import AppKit
import SwiftUI

/// Slack's profile card: what the room already knows about a person, at once, with the fetched profile replacing
/// it quietly. Shown in a `PopoverHost`.
struct ProfileCard: View {
    let matrix: MatrixService
    let people: PeopleService
    let userID: String
    var fallback: ChatUser? = nil
    var onOpenConversation: (String) -> Void
    var onViewProfile: () -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let person = ProfileDetails(people: people, userID: userID, fallback: fallback)
        let colors = appearance.colors
        VStack(alignment: .leading, spacing: m.sp12) {
            Button(action: onViewProfile) {
                AvatarView(
                    name: person.name, size: m.popoverWidth - 2 * m.sp16, cornerRadius: m.radiusLarge,
                    matrix: matrix, source: person.avatarURL)
            }.buttonStyle(.row).help("View full profile")
            ProfileHeading(person: person, own: userID == matrix.user?.id)
            HStack(spacing: m.sp8) {
                if userID != matrix.user?.id {
                    MessageButton(matrix: matrix, userID: userID, onOpen: onOpenConversation)
                }
                ProfileMenu(userID: userID, onViewProfile: onViewProfile)
            }
        }
        .foregroundStyle(colors.textBody)
        .task(id: userID) { await people.loadProfile(userID: userID, fallback: fallback) }
    }
}

/// Slack's full profile, in the right-hand pane beside the conversation.
struct ProfilePane: View {
    private static let photoSide: CGFloat = 256
    let matrix: MatrixService
    let people: PeopleService
    let userID: String
    var fallback: ChatUser? = nil
    var onOpenConversation: (String) -> Void
    var onClose: () -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let person = ProfileDetails(people: people, userID: userID, fallback: fallback)
        let colors = appearance.colors
        VStack(spacing: 0) {
            HStack {
                Text("Profile").font(m.font(.title, .bold))
                Spacer()
                IconButton(symbol: "xmark", label: "Close profile", role: .body, action: onClose)
            }.padding(.horizontal, m.sp20).frame(height: m.paneHeader)
            Divider().overlay(colors.border)
            ScrollView {
                VStack(alignment: .leading, spacing: m.sp16) {
                    AvatarView(
                        name: person.name, size: m(Self.photoSide), cornerRadius: m.radiusPanel, matrix: matrix,
                        source: person.avatarURL
                    ).frame(maxWidth: .infinity)
                    ProfileHeading(person: person, own: userID == matrix.user?.id)
                    HStack(spacing: m.sp8) {
                        if userID != matrix.user?.id {
                            MessageButton(matrix: matrix, userID: userID, onOpen: onOpenConversation)
                        }
                        ProfileMenu(userID: userID, onViewProfile: nil)
                    }
                    Divider().overlay(colors.border)
                    VStack(alignment: .leading, spacing: m.sp4) {
                        Text("Matrix ID").font(m.font(.secondary, .semibold)).foregroundStyle(colors.textPrimary)
                        Text(userID).font(m.font(.secondary)).foregroundStyle(colors.textSecondary)
                            .textSelection(.enabled)
                    }
                }.padding(m.sp20)
            }
        }
        .foregroundStyle(colors.textBody).background(colors.canvas)
        .task(id: userID) { await people.loadProfile(userID: userID, fallback: fallback) }
    }
}

/// The name, photo and status to show: the fetched profile once it is in, the room's member until then.
private struct ProfileDetails {
    let name: String
    let avatarURL: String?
    let status: String?
    let userID: String

    @MainActor init(people: PeopleService, userID: String, fallback: ChatUser?) {
        let profile = people.profile?.id == userID ? people.profile : nil
        let known = fallback?.id == userID ? fallback : nil
        self.userID = userID
        name = profile?.name ?? known?.name ?? userID
        avatarURL = profile?.avatarURL ?? known?.avatarURL
        status = people.statusSupported ? profile?.status : nil
    }
}

private struct ProfileHeading: View {
    let person: ProfileDetails
    let own: Bool
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        VStack(alignment: .leading, spacing: m.sp4) {
            HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                Text(person.name).font(m.font(.title, .bold)).foregroundStyle(colors.textPrimary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if own { TagLabel(text: "You") }
            }
            Text(person.userID).font(m.font(.secondary)).foregroundStyle(colors.textSecondary).lineLimit(1)
                .truncationMode(.middle).textSelection(.enabled)
            if let status = person.status, !status.isEmpty {
                Text(status).font(m.font(.secondary)).foregroundStyle(colors.textBody)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, m.sp4)
            }
        }
    }
}

/// Opens or creates the direct message; the spinner waits like every other, and a failure shows under it.
private struct MessageButton: View {
    let matrix: MatrixService
    let userID: String
    let onOpen: (String) -> Void
    @State private var request: UUID?
    @State private var error: String?
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            Button(action: open) {
                HStack(spacing: m.sp8) {
                    if request != nil { DelayedProgress() }
                    Text("Message")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .disabled(request != nil || matrix.isPreview || (try? PeopleMapping.validatedID(userID)) == nil)
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
}

/// Slack's ⋯ beside Message: copy the ID, and from the card, open the full profile. A native menu, as everywhere.
private struct ProfileMenu: View {
    let userID: String
    let onViewProfile: (() -> Void)?
    @Environment(\.metrics) private var m

    var body: some View {
        Button(action: show) {
            Image(systemName: "ellipsis").font(m.font(.body)).accessibilityLabel("More actions")
        }.buttonStyle(.secondary).help("More actions")
    }

    private func show() {
        var commands: [MessageMenuCommand] = []
        if let onViewProfile {
            commands.append(MessageMenuCommand(id: "view-profile", title: "View full profile", perform: onViewProfile))
        }
        commands.append(
            MessageMenuCommand(id: "copy-id", title: "Copy member ID") { [userID] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(userID, forType: .string)
            })
        NativeMessageMenu.make(commands: commands).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
