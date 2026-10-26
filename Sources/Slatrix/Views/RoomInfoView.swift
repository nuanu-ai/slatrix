import AppKit
import SwiftUI

/// Slack's channel details: a large modal with About, Members and Settings tabs.
struct RoomInfoView: View {
    enum Tab: Hashable { case about, members, settings }
    private static let height: CGFloat = 640
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    var room: ChatRoom
    @State var tab = Tab.about
    var onClose: () -> Void
    var onInvite: () -> Void
    var onRecovery: () -> Void
    var onOpenProfile: (String, ChatUser?) -> Void
    var onEditDetails: () -> Void
    var onNotifications: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var busy = false
    @State private var loadingMembers = false
    @State private var memberSearch = ""
    @State private var error: String?
    @State private var copied = false
    @State private var confirmLeave = false

    private var colors: AppColors { appearance.colors }
    private var currentRoom: ChatRoom { matrix.rooms.first(where: { $0.id == room.id }) ?? room }
    private var members: [ChatUser] {
        matrix.members.filter {
            memberSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(memberSearch)
                || $0.id.localizedCaseInsensitiveContains(memberSearch)
        }
    }

    var body: some View {
        Modal(
            title: currentRoom.isDirect ? currentRoom.name : "# \(currentRoom.name)", size: .large,
            height: Self.height, padded: false, onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: 0) {
                TabBar(
                    tabs: [
                        .init(value: .about, title: "About"),
                        .init(
                            value: .members, title: "Members",
                            count: currentRoom.memberCount > 0 ? currentRoom.memberCount : nil),
                        .init(value: .settings, title: "Settings"),
                    ], selection: $tab
                ).padding(.horizontal, m.sp24)
                Divider().overlay(colors.border)
                if let error { InlineErrorView(message: error, dismiss: { self.error = nil }) }
                switch tab {
                case .about: aboutContent
                case .members: membersContent
                case .settings: settingsContent
                }
            }
        }
        .task(id: room.id) {
            error = nil
            busy = false
            loadingMembers = true
            await matrix.loadMembers()
            loadingMembers = false
        }
        .task(id: copied) {
            if copied {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
        }
        .modal(isPresented: $confirmLeave) {
            ConfirmModal(
                title: "Leave \(currentRoom.name)?", message: "You may need an invitation to rejoin.", action: "Leave",
                onConfirm: {
                    confirmLeave = false
                    let destination = room.id
                    let session = matrix.notificationSessionID
                    perform {
                        try await matrix.leaveRoom(destination)
                        if matrix.notificationSessionID == session, matrix.selectedRoomID == destination { onClose() }
                    }
                }, onCancel: { confirmLeave = false })
        }
    }

    private var aboutContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.sp24) {
                section("Description") {
                    Text(currentRoom.topic.isEmpty ? "No description" : currentRoom.topic)
                        .font(m.font(.secondary)).foregroundStyle(
                            currentRoom.topic.isEmpty ? colors.textSecondary : colors.textBody
                        )
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !matrix.isPreview, currentRoom.membership == "join" {
                        Button("Edit", action: onEditDetails).buttonStyle(.textLink).font(m.font(.meta))
                            .disabled(busy)
                    }
                }
                section(currentRoom.isDirect ? "Room ID" : "Channel ID") {
                    Text(currentRoom.id).font(m.font(.caption, design: .monospaced)).foregroundStyle(
                        colors.textSecondary
                    )
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(currentRoom.id, forType: .string)
                        copied = true
                    } label: {
                        Label(
                            copied ? "Copied" : currentRoom.isDirect ? "Copy room ID" : "Copy channel ID",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                        .font(m.font(.meta))
                    }
                    .buttonStyle(.textLink)
                }
                Divider().overlay(colors.border)
                if matrix.isPreview {
                    Text("Sign in to manage this conversation.").font(m.font(.meta)).foregroundStyle(
                        colors.textSecondary)
                }
                HStack(spacing: m.sp12) {
                    Button(currentRoom.isDirect ? "Leave conversation" : "Leave channel") { confirmLeave = true }
                        .buttonStyle(.row).font(m.font(.secondary, .semibold)).foregroundStyle(colors.destructive)
                        .disabled(busy || matrix.isPreview)
                    if busy { DelayedProgress().accessibilityLabel("Updating conversation") }
                }
            }.padding(m.sp24)
        }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.sp24) {
                section("Preferences") {
                    VStack(spacing: m.sp16) {
                        Toggle(
                            isOn: Binding(
                                get: { currentRoom.favorite },
                                set: { value in perform { try await matrix.setFavorite(currentRoom, value: value) } })
                        ) {
                            Label("Add to Starred", systemImage: "star").font(m.font(.secondary))
                        }.toggleStyle(.switch).controlSize(.small)
                        Button(action: onNotifications) {
                            HStack {
                                Label("Notifications", systemImage: currentRoom.muted ? "bell.slash" : "bell").font(
                                    m.font(.secondary))
                                Spacer()
                                Image(systemName: "chevron.right").font(m.font(.caption)).foregroundStyle(
                                    colors.textSecondary)
                            }
                        }.buttonStyle(.row).disabled(currentRoom.membership != "join")
                    }.disabled(busy || matrix.isPreview)
                }
                section("Encryption") {
                    Label(
                        currentRoom.isEncrypted ? "End-to-end encrypted" : "Not encrypted",
                        systemImage: currentRoom.isEncrypted ? "lock.shield" : "lock.open"
                    )
                    .font(m.font(.meta, .medium))
                    if currentRoom.isEncrypted {
                        Button("Unlock history…", action: onRecovery).buttonStyle(.textLink).font(m.font(.meta))
                            .disabled(matrix.isPreview)
                    }
                }
                section("Workspaces") { workspaces }
            }.padding(m.sp24)
        }
    }

    @ViewBuilder private var workspaces: some View {
        let linked = matrix.workspaces.filter { currentRoom.spaceIDs.contains($0.id) }
        if linked.isEmpty {
            Text("None").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
        } else {
            ForEach(linked) { workspace in
                HStack(spacing: m.sp8) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(colors.textSecondary)
                    VStack(alignment: .leading, spacing: m.sp4) {
                        Text(workspace.name).font(m.font(.secondary))
                        if !currentRoom.directParentSpaceIDs.contains(workspace.id) {
                            Text("Through another workspace").font(m.font(.caption))
                                .foregroundStyle(colors.textSecondary)
                        }
                    }
                }
            }
        }
        if !matrix.workspaces.isEmpty {
            Menu {
                ForEach(matrix.workspaces) { workspace in
                    let direct = currentRoom.directParentSpaceIDs.contains(workspace.id)
                    let inherited = !direct && currentRoom.spaceIDs.contains(workspace.id)
                    Button {
                        perform {
                            if direct {
                                try await matrix.removeRoomFromWorkspace(spaceID: workspace.id, roomID: room.id)
                            } else {
                                try await matrix.addRoomToWorkspace(spaceID: workspace.id, roomID: room.id)
                            }
                        }
                    } label: {
                        Label(
                            "\(direct ? "Remove from" : inherited ? "Add directly to" : "Add to") \(workspace.name)",
                            systemImage: direct ? "minus.circle" : "plus.circle")
                    }.disabled(workspace.canManageRooms == false)
                }
            } label: {
                Label("Manage workspaces", systemImage: "square.stack.3d.up").font(m.font(.meta))
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(busy || matrix.isPreview)
        }
    }

    private var membersContent: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            SearchField(prompt: "Find members", text: $memberSearch).padding(.horizontal, m.sp24).padding(
                .top, m.sp16)
            ScrollView {
                LazyVStack(spacing: 0) {
                    Button(action: onInvite) {
                        HStack(spacing: m.sp12) {
                            Image(systemName: "person.badge.plus").font(m.font(.body)).frame(
                                width: m.avatar, height: m.avatar
                            )
                            .background(colors.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: m.radius))
                            Text("Add people").font(m.font(.body, .semibold))
                            Spacer(minLength: 0)
                        }.foregroundStyle(colors.accent).padding(.horizontal, m.sp12).frame(height: m.personRow)
                    }.buttonStyle(.row).disabled(
                        busy || matrix.isPreview || currentRoom.membership != "join" || currentRoom.canInvite == false)
                    if loadingMembers && matrix.members.isEmpty {
                        DelayedProgress().frame(maxWidth: .infinity).padding(.top, m.sp16)
                    } else if members.isEmpty {
                        VStack(spacing: m.sp8) {
                            Text(memberSearch.isEmpty ? "No members to show" : "No matches").font(
                                m.font(.meta)
                            ).foregroundStyle(colors.textSecondary)
                            if memberSearch.isEmpty {
                                Button("Reload members") {
                                    Task {
                                        loadingMembers = true
                                        await matrix.loadMembers()
                                        loadingMembers = false
                                    }
                                }.buttonStyle(.textLink).font(m.font(.meta))
                            }
                        }.padding(m.sp16).frame(maxWidth: .infinity)
                    }
                    ForEach(members) { member in
                        PersonRow(
                            name: member.name, userID: member.id, isYou: member.id == matrix.user?.id, matrix: matrix,
                            avatarSource: member.avatarURL
                        ) { onOpenProfile(member.id, member) }
                    }
                }.padding(.horizontal, m.sp12).padding(.bottom, m.sp12)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            Text(title).font(m.font(.secondary, .semibold)).foregroundStyle(colors.textPrimary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !matrix.isPreview else { return }
        busy = true
        error = nil
        let destination = room.id
        let session = matrix.notificationSessionID
        Task { @MainActor in
            guard matrix.notificationSessionID == session, matrix.selectedRoomID == destination else { return }
            do { try await operation() } catch is CancellationError {} catch {
                if matrix.notificationSessionID == session, matrix.selectedRoomID == destination {
                    self.error = MatrixService.safeError(error)
                }
            }
            guard matrix.notificationSessionID == session, matrix.selectedRoomID == destination else { return }
            busy = false
        }
    }
}

struct EncryptionRecoveryView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var recoveryKey = ""
    @State private var busy = false
    @State private var recovered = false
    @State private var error: String?
    private var colors: AppColors { appearance.colors }

    var body: some View {
        Modal(
            title: recovered ? "History unlocked" : "Unlock encrypted history", busy: busy, onClose: close,
            secondary: recovered ? nil : ModalAction("Cancel", action: close),
            primary: recovered
                ? ModalAction("Done", action: close)
                : ModalAction(
                    "Unlock",
                    disabled: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || matrix.isPreview,
                    action: recover)
        ) {
            if recovered {
                Label("Older messages may take a moment to appear.", systemImage: "checkmark.shield")
                    .font(m.font(.secondary)).foregroundStyle(colors.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: m.sp8) {
                    Text("Recovery key").font(m.font(.secondary, .semibold))
                    SecureField("", text: $recoveryKey)
                        .textFieldStyle(.plain).font(m.font(.body, design: .monospaced)).padding(m.sp12)
                        .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radius))
                        .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(colors.textSecondary.opacity(0.5)))
                        .disabled(busy).accessibilityLabel("Recovery key")
                }
            }
            if let error { InlineErrorView(message: error).clipShape(RoundedRectangle(cornerRadius: m.radius)) }
            if matrix.isPreview {
                Text("Sign in first.").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
            }
        }
        .onDisappear { recoveryKey = "" }
    }

    private func close() {
        recoveryKey = ""
        onClose()
    }

    private func recover() {
        guard !busy, !matrix.isPreview else { return }
        let key = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        busy = true
        error = nil
        Task { @MainActor in
            do {
                try await matrix.recoverEncryption(recoveryKey: key)
                recoveryKey = ""
                recovered = true
            } catch {
                self.error = MatrixService.safeError(error)
            }
            busy = false
        }
    }
}
