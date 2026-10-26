import SwiftUI

/// Slack's ⌘K: jump to a conversation. Recent ones while the field is empty; ↑ ↓ move, Return opens, Esc closes. A
/// pasted Matrix link opens too.
struct QuickSwitcherView: View {
    /// Ten rows and a half, so the list never resizes as results come and go, and a cut row says it scrolls.
    private static let listHeight: CGFloat = 352
    let matrix: MatrixService
    /// Conversations opened in this window, oldest first.
    let visited: [String]
    var onSelect: (String) -> Void
    var onMatrixLink: (URL) -> Void
    var onClose: () -> Void
    @State private var query = ""
    @State private var selectedIndex = 0
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    private var results: [ChatRoom] { ConversationSwitcher.results(matrix.rooms, query: query, visited: visited) }
    private var matrixLink: URL? {
        URL(string: query.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            MatrixLinkService.isMatrixCandidate($0) ? $0 : nil
        }
    }
    private var selection: Int { min(selectedIndex, max(results.count - 1, 0)) }

    var body: some View {
        let colors = appearance.colors
        let results = results
        VStack(spacing: 0) {
            SearchField(prompt: "Jump to…", text: $query, onEscape: onClose)
                .onSubmit(openSelected)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .padding(m.sp12)
            Divider().overlay(colors.border)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let matrixLink {
                            MenuRow(title: "Open link", detail: matrixLink.absoluteString, selected: true) {
                                onClose()
                                onMatrixLink(matrixLink)
                            } icon: {
                                Image(systemName: "link").font(m.font(.secondary))
                            }
                        } else {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, room in
                                MenuRow(title: room.name, detail: detail(room), selected: index == selection) {
                                    onSelect(room.id)
                                } icon: {
                                    RoomIcon(room: room, matrix: matrix)
                                }.id(room.id)
                            }
                        }
                    }.padding(m.sp8)
                }
                .overlay {
                    if results.isEmpty && matrixLink == nil {
                        Text("No conversations found").font(m.font(.secondary)).foregroundStyle(colors.textSecondary)
                    }
                }
                .onChange(of: selection) { _, index in
                    if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                }
            }
            .frame(height: m(Self.listHeight))
        }
        .frame(width: m.modalMedium).background(colors.canvas).foregroundStyle(colors.textBody)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    /// The workspace a channel belongs to, so two "general"s tell apart.
    private func detail(_ room: ChatRoom) -> String? {
        room.isDirect ? nil : matrix.workspaces.first { room.spaceIDs.contains($0.id) }?.name
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        selectedIndex = (selection + step + results.count) % results.count
        return .handled
    }

    private func openSelected() {
        if let matrixLink {
            onClose()
            onMatrixLink(matrixLink)
        } else if results.indices.contains(selection) {
            onSelect(results[selection].id)
        }
    }
}

enum CreationKind: String, Identifiable {
    case directMessage, channel, workspace, join, invite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .directMessage: "New message"
        case .channel: "Create a channel"
        case .workspace: "Create a workspace"
        case .join: "Join a conversation"
        case .invite: "Invite people"
        }
    }
    var action: String {
        switch self {
        case .directMessage: "Go"
        case .channel: "Create channel"
        case .workspace: "Create workspace"
        case .join: "Join"
        case .invite: "Invite"
        }
    }
}

struct CreationSheet: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    var kind: CreationKind
    var workspaceID: String? = nil
    var roomID: String? = nil
    var onCreated: (String, Bool, String?) -> Void
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var name = ""
    @State private var topic = ""
    @State private var identifier = ""
    @State private var selectedWorkspaceID = ""
    @State private var busy = false
    @State private var error: String?
    @State private var submission = UUID()

    private var colors: AppColors { appearance.colors }
    private var trimmedIdentifier: String { identifier.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var account: PeopleAccountIdentity {
        PeopleAccountIdentity(userID: matrix.user?.id, isPreview: matrix.isPreview)
    }
    private struct FormIdentity: Equatable {
        let account: PeopleAccountIdentity
        let session: UUID
    }
    private struct SubmissionContext: Equatable {
        let identity: FormIdentity
        let kind: CreationKind
        let roomID: String?
        let workspaceID: String
    }
    private var formIdentity: FormIdentity { FormIdentity(account: account, session: matrix.notificationSessionID) }
    private var submissionContext: SubmissionContext {
        SubmissionContext(identity: formIdentity, kind: kind, roomID: roomID, workspaceID: selectedWorkspaceID)
    }
    private var inviteWorkspace: Workspace? { matrix.workspaces.first { $0.id == roomID } }
    private var inviteRoom: ChatRoom? { matrix.rooms.first { $0.id == roomID } }
    private var invitePermission: Bool? { inviteWorkspace?.canInvite ?? inviteRoom?.canInvite }
    private var valid: Bool {
        guard !matrix.isPreview, !busy else { return false }
        switch kind {
        case .directMessage: return Self.validIdentifier(trimmedIdentifier, prefixes: ["@"])
        case .invite:
            return roomID != nil && invitePermission != false
                && Self.validIdentifier(trimmedIdentifier, prefixes: ["@"])
        case .join: return Self.validIdentifier(trimmedIdentifier, prefixes: ["#", "!"])
        case .channel, .workspace:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (kind != .channel || selectedWorkspaceID.isEmpty
                    || matrix.workspaces.contains { $0.id == selectedWorkspaceID && $0.canManageRooms != false })
        }
    }

    var body: some View {
        Modal(
            title: kind.title, busy: busy, onClose: onClose, secondary: ModalAction("Cancel", action: onClose),
            primary: ModalAction(
                kind.action, disabled: !valid,
                // Return picks a suggested person in these, so it never sends the form.
                shortcut: kind == .directMessage || kind == .invite ? nil : .defaultAction, action: submit)
        ) {
            VStack(alignment: .leading, spacing: m.sp20) {
                switch kind {
                case .directMessage, .invite:
                    PersonRecipientPicker(matrix: matrix, people: matrix.people, recipientID: $identifier)
                    if kind == .invite, let workspace = inviteWorkspace {
                        VStack(alignment: .leading, spacing: m.sp8) {
                            Label("To \(workspace.name)", systemImage: "square.stack.3d.up").font(
                                m.font(.meta))
                        }.foregroundStyle(colors.textSecondary)
                    } else if kind == .invite, let room = inviteRoom {
                        HStack(spacing: m.sp8) {
                            Image(systemName: room.isDirect ? "bubble.left.and.bubble.right" : "number")
                            Text("To \(room.name)")
                        }.font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                    } else if kind == .invite, let roomID {
                        Label("To \(roomID)", systemImage: "person.badge.plus").font(m.font(.meta))
                            .foregroundStyle(colors.textSecondary)
                    } else if kind == .invite && roomID == nil {
                        Text("Open a conversation first.").font(m.font(.meta)).foregroundStyle(
                            colors.warning)
                    }
                    if kind == .invite && invitePermission == false {
                        Text("You can’t invite people here.").font(m.font(.meta))
                            .foregroundStyle(colors.warning)
                    }
                case .channel, .workspace:
                    field(
                        kind == .channel ? "Name" : "Workspace name"
                    ) {
                        TextField(kind == .channel ? "e.g. design-team" : "e.g. Harbor", text: $name)
                    }
                    field("Description", optional: true) {
                        TextField(
                            "What is this \(kind == .channel ? "channel" : "workspace") for?", text: $topic,
                            axis: .vertical
                        ).lineLimit(2...4)
                    }
                    if kind == .channel && !matrix.workspaces.isEmpty {
                        VStack(alignment: .leading, spacing: m.sp8) {
                            Text("Workspace").font(m.font(.secondary, .semibold))
                            Picker("Workspace", selection: $selectedWorkspaceID) {
                                Text("No workspace").tag("")
                                ForEach(matrix.workspaces) { workspace in
                                    Text(workspace.name).tag(workspace.id).disabled(workspace.canManageRooms == false)
                                }
                            }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                            if matrix.workspaces.first(where: { $0.id == selectedWorkspaceID })?.canManageRooms == false
                            {
                                Text("You can’t add channels to this workspace.").font(
                                    m.font(.meta)
                                ).foregroundStyle(colors.warning)
                            }
                        }
                    }
                case .join:
                    field("Address") {
                        TextField("#channel:server.org", text: $identifier)
                    }
                }
            }.disabled(busy)
            if let error { InlineErrorView(message: error).clipShape(RoundedRectangle(cornerRadius: m.radius)) }
        }
        .onAppear { selectedWorkspaceID = workspaceID ?? "" }
        .onChange(of: formIdentity) { _, _ in
            submission = UUID()
            busy = false
            onClose()
        }
        .onChange(of: submissionContext) { _, _ in
            if busy {
                submission = UUID()
                busy = false
                onClose()
            }
        }
        .onDisappear { submission = UUID() }
    }

    private func field<Content: View>(
        _ title: String, optional: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            HStack(spacing: m.sp4) {
                Text(title).font(m.font(.secondary, .semibold))
                if optional { Text("(optional)").font(m.font(.meta)).foregroundStyle(colors.textSecondary) }
            }
            content().textFieldStyle(.field).accessibilityLabel(title)
        }
    }

    private static func validIdentifier(_ value: String, prefixes: Set<Character>) -> Bool {
        guard let first = value.first, prefixes.contains(first), !value.contains(where: { $0.isWhitespace }) else {
            return false
        }
        let components = value.dropFirst().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return components.count == 2 && !components[0].isEmpty && !components[1].isEmpty
    }

    private func submit() {
        guard valid else { return }
        busy = true
        error = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = trimmedIdentifier
        let request = UUID()
        let context = submissionContext
        submission = request
        Task { @MainActor in
            guard submission == request, submissionContext == context, !Task.isCancelled else { return }
            do {
                let id: String
                switch context.kind {
                case .directMessage: id = try await matrix.createDM(userID: identifier)
                case .channel:
                    id = try await matrix.createRoom(
                        name: name, topic: topic, workspaceID: context.workspaceID.isEmpty ? nil : context.workspaceID)
                case .workspace: id = try await matrix.createWorkspace(name: name, topic: topic)
                case .join: id = try await matrix.joinRoom(identifier)
                case .invite:
                    guard let roomID = context.roomID else {
                        busy = false
                        return
                    }
                    try await matrix.invite(userID: identifier, roomID: roomID)
                    id = roomID
                }
                guard submission == request, submissionContext == context, !Task.isCancelled else { return }
                busy = false
                onCreated(id, context.kind == .workspace, nil)
                onClose()
            } catch let partial as RoomCreationPartialFailure {
                guard submission == request, submissionContext == context else { return }
                busy = false
                onCreated(partial.roomID, false, partial.warning)
                onClose()
            } catch is CancellationError {
                if submission == request, submissionContext == context { busy = false }
            } catch {
                guard submission == request, submissionContext == context else { return }
                self.error = MatrixService.safeError(error)
                busy = false
            }
        }
    }
}
