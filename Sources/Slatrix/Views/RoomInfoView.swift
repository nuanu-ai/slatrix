import AppKit
import SwiftUI

struct RoomInfoView: View {
    /// Matches the thread pane header so both panes line up.
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    var room: ChatRoom
    var onClose: () -> Void
    var onInvite: () -> Void
    var onRecovery: () -> Void
    var onOpenProfile: (String, ChatUser?) -> Void
    var onEditDetails: () -> Void
    var onNotifications: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var tab = InfoTab.about
    @State private var busy = false
    @State private var loadingMembers = false
    @State private var memberSearch = ""
    @State private var error: String?
    @State private var copied = false
    @State private var confirmLeave = false

    private enum InfoTab: String, CaseIterable {
        case about = "About"
        case members = "Members"
    }
    private var colors: AppColors { appearance.colors }
    private var currentRoom: ChatRoom { matrix.rooms.first(where: { $0.id == room.id }) ?? room }
    private var members: [ChatUser] {
        matrix.members.filter {
            memberSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(memberSearch)
                || $0.id.localizedCaseInsensitiveContains(memberSearch)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Details").font(m.font(.body, .semibold))
                Spacer()
                IconButton(symbol: "xmark", label: "Close", role: .secondary, action: onClose)
            }.padding(.horizontal, m.sp16).frame(height: m.paneHeader)
            Divider().overlay(colors.border)
            VStack(alignment: .leading, spacing: m.sp16) {
                HStack(alignment: .center, spacing: m.sp12) {
                    if currentRoom.isDirect {
                        AvatarView(
                            name: currentRoom.name, size: m.avatar, matrix: matrix, source: currentRoom.avatarURL)
                    } else {
                        Image(systemName: currentRoom.isEncrypted ? "lock" : "number").font(
                            m.font(.header, .medium)
                        )
                        .frame(width: m.avatar, height: m.avatar).background(
                            colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                    }
                    VStack(alignment: .leading, spacing: m.sp4) {
                        Text(currentRoom.name).font(m.font(.title, .bold)).foregroundStyle(
                            colors.textPrimary
                        ).lineLimit(2)
                        Text(currentRoom.isDirect ? "Direct message" : "Channel").font(m.font(.caption))
                            .foregroundStyle(colors.textSecondary)
                    }
                }
                Picker("Conversation details", selection: $tab) {
                    Text("About").tag(InfoTab.about)
                    Text("Members\(currentRoom.memberCount > 0 ? " · \(currentRoom.memberCount)" : "")").tag(
                        InfoTab.members)
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(m.sp16)
            if let error { InlineErrorView(message: error, dismiss: { self.error = nil }) }
            if tab == .about { aboutContent } else { membersContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.canvas).foregroundStyle(colors.textBody)
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
        .alert("Leave \(currentRoom.name)?", isPresented: $confirmLeave) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                let destination = room.id
                let session = matrix.notificationSessionID
                perform {
                    try await matrix.leaveRoom(destination)
                    if matrix.notificationSessionID == session, matrix.selectedRoomID == destination { onClose() }
                }
            }
        } message: {
            Text("You may need an invitation to rejoin.")
        }
    }

    private var aboutContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.sp20) {
                section("Description") {
                    Text(currentRoom.topic.isEmpty ? "No description" : currentRoom.topic)
                        .font(m.font(.secondary)).foregroundStyle(
                            currentRoom.topic.isEmpty ? colors.textSecondary : colors.textBody
                        )
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !matrix.isPreview, currentRoom.membership == "join" {
                        Button(action: onEditDetails) {
                            Label("Edit details", systemImage: "pencil").font(m.font(.meta))
                        }.buttonStyle(.textLink).disabled(busy)
                    }
                }
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
                    VStack(alignment: .leading, spacing: m.sp8) {
                        Label(
                            currentRoom.isEncrypted ? "End-to-end encrypted" : "Not encrypted",
                            systemImage: currentRoom.isEncrypted ? "lock.shield" : "lock.open"
                        )
                        .font(m.font(.meta, .medium))
                        if currentRoom.isEncrypted {
                            Button("Unlock history…", action: onRecovery).buttonStyle(.textLink).font(
                                m.font(.meta)
                            ).disabled(matrix.isPreview)
                        }
                    }
                }
                section("Workspaces") {
                    VStack(alignment: .leading, spacing: m.sp12) {
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
                                                try await matrix.removeRoomFromWorkspace(
                                                    spaceID: workspace.id, roomID: room.id)
                                            } else {
                                                try await matrix.addRoomToWorkspace(
                                                    spaceID: workspace.id, roomID: room.id)
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
                }
                section(currentRoom.isDirect ? "Room ID" : "Channel ID") {
                    VStack(alignment: .leading, spacing: m.sp8) {
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
                }
                Divider().overlay(colors.border)
                if matrix.isPreview {
                    Text("Sign in to manage this conversation.").font(m.font(.meta)).foregroundStyle(
                        colors.textSecondary)
                }
                Button(role: .destructive) {
                    confirmLeave = true
                } label: {
                    Label("Leave conversation", systemImage: "rectangle.portrait.and.arrow.right").font(
                        m.font(.secondary))
                }.buttonStyle(.row).foregroundStyle(colors.destructive).disabled(busy || matrix.isPreview)
                if busy { DelayedProgress().accessibilityLabel("Updating conversation") }
            }.padding(.horizontal, m.sp20).padding(.bottom, m.sp24)
        }
    }

    private var membersContent: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            SearchField(prompt: "Find a member", text: $memberSearch).padding(.horizontal, m.sp16)
            Button(action: onInvite) {
                HStack(spacing: m.sp12) {
                    Image(systemName: "person.badge.plus").font(m.font(.body)).frame(
                        width: m.iconButton, height: m.iconButton
                    )
                    .background(colors.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: m.radius))
                    Text("Add people").font(m.font(.secondary, .medium))
                }.foregroundStyle(colors.accent).frame(maxWidth: .infinity, alignment: .leading).contentShape(
                    Rectangle())
            }.buttonStyle(.row).padding(.horizontal, m.sp16).disabled(
                busy || matrix.isPreview || currentRoom.membership != "join" || currentRoom.canInvite == false)
            if loadingMembers {
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(members) { member in
                        Button {
                            onOpenProfile(member.id, member)
                        } label: {
                            HStack(spacing: m.sp12) {
                                AvatarView(name: member.name, size: m.avatar, matrix: matrix, source: member.avatarURL)
                                VStack(alignment: .leading, spacing: m.sp4) {
                                    HStack(spacing: m.sp4) {
                                        Text(member.name).font(m.font(.secondary, .medium)).lineLimit(1)
                                        if member.id == matrix.user?.id {
                                            Text("(you)").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                                        }
                                    }
                                    Text(member.id).font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(m.font(.caption)).foregroundStyle(
                                    colors.textSecondary)
                            }.padding(.horizontal, m.sp16).padding(.vertical, m.sp8).contentShape(Rectangle())
                        }.buttonStyle(.row).help("View \(member.name)’s profile").accessibilityLabel(
                            "View profile, \(member.name), \(member.id)")
                    }
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            Text(title).font(m.font(.meta, .semibold)).foregroundStyle(colors.textPrimary)
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
    private static let width: CGFloat = 480
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var recoveryKey = ""
    @State private var busy = false
    @State private var recovered = false
    @State private var error: String?
    @FocusState private var keyFocused: Bool
    private var colors: AppColors { appearance.colors }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp20) {
            HStack {
                Image(systemName: recovered ? "checkmark.shield" : "lock.shield").font(
                    m.font(.display)
                ).foregroundStyle(recovered ? colors.success : colors.accent)
                Spacer()
                IconButton(symbol: "xmark", label: "Close", role: .secondary) { close() }.disabled(
                    busy)
            }
            VStack(alignment: .leading, spacing: m.sp8) {
                Text(recovered ? "History unlocked" : "Unlock encrypted history").font(
                    m.font(.header, .bold)
                ).foregroundStyle(colors.textPrimary)
                if recovered {
                    Text("Older messages may take a moment to appear.").font(m.font(.secondary)).foregroundStyle(
                        colors.textSecondary)
                }
            }
            if !recovered {
                VStack(alignment: .leading, spacing: m.sp8) {
                    Text("Recovery key").font(m.font(.secondary, .semibold))
                    SecureField("", text: $recoveryKey)
                        .textFieldStyle(.plain).font(m.font(.body, design: .monospaced)).padding(m.sp12)
                        .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radius))
                        .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(colors.textSecondary.opacity(0.5)))
                        .focused($keyFocused).disabled(busy).accessibilityLabel("Recovery key")
                }
            }
            if let error { InlineErrorView(message: error).clipShape(RoundedRectangle(cornerRadius: m.radius)) }
            if matrix.isPreview {
                Text("Sign in first.").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
            }
            HStack(spacing: m.sp12) {
                if busy {
                    DelayedProgress()
                    Text("Unlocking…").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                }
                Spacer()
                if !recovered { Button("Cancel") { close() }.disabled(busy).keyboardShortcut(.cancelAction) }
                Button(recovered ? "Done" : "Unlock") { if recovered { close() } else { recover() } }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    .disabled(
                        busy
                            || (!recovered
                                && (recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || matrix.isPreview))
                    )
            }.padding(.top, m.sp4)
        }
        .padding(m.sp32).sheetSize(width: Self.width).background(colors.canvas).foregroundStyle(colors.textBody)
        .interactiveDismissDisabled(busy)
        .onAppear { keyFocused = true }
        .onDisappear { recoveryKey = "" }
        .onExitCommand { if !busy { close() } }
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
