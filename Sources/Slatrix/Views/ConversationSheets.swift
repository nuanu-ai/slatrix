import SwiftUI

struct QuickSwitcherView: View {
    private static let size = CGSize(width: 672, height: 560)
    private static let modeWidth: CGFloat = 240
    private static let scopeWidth: CGFloat = 256
    private static let matchingWidth: CGFloat = 156
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    var onSelect: (String) -> Void
    var onClose: () -> Void
    var onMessageSelect: ((ChatMessage) -> Void)? = nil
    var initiallyMessages: Bool = false
    var initialRoomID: String? = nil
    var onMatrixLink: ((URL) -> Void)? = nil
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var query = ""
    @State private var mode = SearchMode.conversations
    @State private var scopeRoomID = ""
    @State private var queryMode = MessageSearchQuery.Mode.query
    @State private var selectedIndex = 0
    @State private var searching = false
    @State private var paging = false
    @State private var startingIndex = false
    @State private var error: String?
    @State private var searchRevision = 0
    @State private var searchPresented = true
    @State private var presentationSession: UUID
    @State private var activeRequest: SearchRequest?
    @State private var initialized = false
    @FocusState private var searchFocused: Bool

    @MainActor init(
        matrix: MatrixService, onSelect: @escaping (String) -> Void, onClose: @escaping () -> Void,
        onMessageSelect: ((ChatMessage) -> Void)? = nil, initiallyMessages: Bool = false,
        initialRoomID: String? = nil, onMatrixLink: ((URL) -> Void)? = nil
    ) {
        self.matrix = matrix
        self.onSelect = onSelect
        self.onClose = onClose
        self.onMessageSelect = onMessageSelect
        self.initiallyMessages = initiallyMessages
        self.initialRoomID = initialRoomID
        self.onMatrixLink = onMatrixLink
        _presentationSession = State(initialValue: matrix.notificationSessionID)
    }

    private enum SearchMode: String, CaseIterable, Hashable {
        case conversations = "Conversations"
        case messages = "Messages"
    }
    private struct SearchRequest: Hashable {
        var mode: SearchMode
        var messageQuery: MessageSearchQuery
        var roomID: String?
        var query: String { messageQuery.text }
    }
    private enum ResultID: Hashable {
        case room(String)
        case message(roomID: String, eventID: String)
    }
    private var colors: AppColors { appearance.colors }
    private var request: SearchRequest {
        SearchRequest(
            mode: mode, messageQuery: MessageSearchQuery(query, mode: mode == .messages ? queryMode : .query),
            roomID: scopeRoomID.isEmpty ? nil : scopeRoomID)
    }
    private var currentRoom: ChatRoom? { matrix.rooms.first { $0.id == matrix.selectedRoomID } }
    private var roomResults: [ChatRoom] {
        matrix.rooms.filter {
            $0.membership != "leave"
                && (request.query.isEmpty || $0.name.localizedCaseInsensitiveContains(request.query))
        }
    }
    private var messages: [ChatMessage] { activeRequest == request && mode == .messages ? matrix.searchResults : [] }
    private var count: Int { mode == .conversations ? roomResults.count : messages.count }
    private var selectedResultID: ResultID? {
        guard count > 0 else { return nil }
        let index = min(selectedIndex, count - 1)
        if mode == .conversations { return .room(roomResults[index].id) }
        let message = messages[index]
        return .message(roomID: message.roomID, eventID: message.eventID)
    }
    private var matrixLink: URL? {
        guard mode == .conversations, onMatrixLink != nil, let url = URL(string: request.query),
            MatrixLinkService.isMatrixCandidate(url)
        else { return nil }
        return url
    }
    private var searchBusy: Bool {
        mode == .messages && (searching || (activeRequest == request && matrix.searchState == "loading"))
    }
    private var indexBusy: Bool { startingIndex || matrix.searchIndexingState.isBusy }
    private var searchError: String? {
        error
            ?? (activeRequest == request && matrix.searchState == "error"
                ? (matrix.searchErrorMessage ?? "Couldn’t search. Try again.") : nil)
    }
    private var terminalSearchFailure: Bool {
        activeRequest == request && mode == .messages && matrix.searchState == "error"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            searchFilters
            Divider().overlay(colors.border)
            results.frame(maxWidth: .infinity, maxHeight: .infinity)
            if mode == .messages { indexingFooter }
            Divider().overlay(colors.border)
            HStack(spacing: m.sp4) {
                Text("↑ ↓").fontWeight(.medium)
                Text("to navigate")
                Text("↵").fontWeight(.medium).padding(.leading, m.sp12)
                Text("to open")
                Spacer()
                Text("esc to close")
            }.font(m.font(.caption)).foregroundStyle(colors.textSecondary).padding(.horizontal, m.sp24).padding(
                .vertical, m.sp12)
        }
        .frame(maxWidth: m(Self.size.width), maxHeight: m(Self.size.height)).background(colors.canvas)
        .foregroundStyle(colors.textBody)
        .onAppear {
            searchPresented = true
            presentationSession = matrix.notificationSessionID
            if !initialized {
                mode = initiallyMessages ? .messages : .conversations
                if initiallyMessages, let initialRoomID { scopeRoomID = initialRoomID }
                initialized = true
            }
            searchFocused = true
        }
        .onChange(of: matrix.selectedRoomID) { _, roomID in if !scopeRoomID.isEmpty { scopeRoomID = roomID ?? "" } }
        .onChange(of: matrix.searchIndexingState) { _, state in
            if (state == .completed || state == .stopped) && mode == .messages && !request.query.isEmpty {
                queueSearch()
            }
        }
        .onExitCommand(perform: close)
        .onDisappear {
            searchPresented = false
            searchRevision += 1
            if presentationSession == matrix.notificationSessionID { matrix.cancelSearch() }
        }
        .task(id: request) { [submitted = request, owner = searchOwner] in await runSearch(submitted, owner: owner) }
    }

    private var searchHeader: some View {
        HStack(spacing: m.sp12) {
            Image(systemName: "magnifyingglass").font(m.font(.title)).foregroundStyle(colors.textSecondary)
            TextField(mode == .conversations ? "Jump to a conversation" : "Search messages", text: $query)
                .font(m.font(.title)).textFieldStyle(.plain).focused($searchFocused)
                .onSubmit(activateSelected)
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .accessibilityLabel(mode == .conversations ? "Find a conversation" : "Search messages")
            if !query.isEmpty {
                IconButton(symbol: "xmark.circle.fill", label: "Clear search", role: .body) {
                    query = ""
                    searchFocused = true
                }
            }
            IconButton(symbol: "xmark", label: "Close", role: .secondary, action: close)
        }.padding(.horizontal, m.sp24).padding(.top, m.sp24).padding(.bottom, m.sp16)
    }

    private var searchFilters: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            HStack {
                Picker("Search in", selection: $mode) {
                    ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: m(Self.modeWidth))
                Spacer()
                if searchBusy {
                    DelayedProgress().accessibilityLabel("Searching").loadingInterval(.searchLoading)
                }
            }
            if mode == .messages {
                HStack(spacing: m.sp12) {
                    Picker("Conversation scope", selection: $scopeRoomID) {
                        Text("All conversations").tag("")
                        if let room = currentRoom { Text("In \(room.name)").tag(room.id) }
                    }.labelsHidden().pickerStyle(.menu).frame(maxWidth: m(Self.scopeWidth), alignment: .leading)
                    Spacer(minLength: 0)
                }
                HStack(spacing: m.sp12) {
                    Picker("Message matching", selection: $queryMode) {
                        ForEach(MessageSearchQuery.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: m(Self.matchingWidth))
                    Spacer(minLength: 0)
                }
            }
        }.padding(.horizontal, m.sp24).padding(.bottom, m.sp16)
    }

    @ViewBuilder private var results: some View {
        if let matrixLink {
            VStack(spacing: m.sp16) {
                Image(systemName: "link").font(m.font(.display)).foregroundStyle(colors.textSecondary)
                Text("Open link").font(m.font(.body, .semibold))
                Text(matrixLink.absoluteString).font(m.font(.caption)).foregroundStyle(colors.textSecondary).lineLimit(
                    3
                )
                .padding(.horizontal, m.sp32)
                Button("Open", action: activateSelected).buttonStyle(.primary)
            }
        } else if let searchError, mode == .messages && count == 0 {
            EmptyStateView(symbol: "exclamationmark.circle", title: searchError) {
                Button("Try again") { queueSearch() }
            }
        } else if mode == .messages && request.query.isEmpty {
            EmptyStateView(symbol: "text.magnifyingglass", title: "Search your messages")
        } else if count == 0 && searchBusy {
            VStack(spacing: m.sp12) {
                DelayedProgress(interval: .searchLoading)
                Text("Searching…").font(m.font(.secondary)).foregroundStyle(colors.textSecondary)
            }
        } else if count == 0 {
            emptyResults
        } else {
            resultList
        }
    }

    @ViewBuilder private var emptyResults: some View {
        if mode == .conversations {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: request.query.isEmpty ? "No conversations yet" : "No conversations found")
        } else if indexBusy {
            EmptyStateView(symbol: "clock.arrow.circlepath", title: "Still indexing recent messages") {
                if matrix.searchHasMore { loadMoreButton }
            }
        } else if matrix.searchHasMore {
            EmptyStateView(symbol: "text.magnifyingglass", title: "No matches yet") { loadMoreButton }
        } else {
            EmptyStateView(symbol: "magnifyingglass", title: "No matches")
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: m.sp2) {
                    if mode == .messages, let searchError {
                        VStack(alignment: .leading, spacing: m.sp8) {
                            InlineErrorView(message: searchError)
                            Button("Try search again") { queueSearch() }
                                .buttonStyle(.textLink).disabled(searchBusy || paging)
                        }.padding(.horizontal, m.sp12).padding(.top, m.sp12)
                    }
                    Text(
                        mode == .conversations
                            ? "CONVERSATIONS" : "MESSAGES"
                    )
                    .font(m.font(.caption, .semibold)).tracking(m(0.8)).foregroundStyle(colors.textSecondary)
                    .padding(.horizontal, m.sp20).padding(.top, m.sp16).padding(.bottom, m.sp8)
                    if mode == .conversations {
                        ForEach(roomResults) { room in
                            resultButton(id: .room(room.id), action: { selectRoom(room.id) }) {
                                roomRow(room, selected: selectedResultID == .room(room.id))
                            }
                        }
                    } else {
                        ForEach(messages) { message in
                            SearchMessageResultRow(
                                matrix: matrix, hit: message,
                                selected: selectedResultID
                                    == .message(roomID: message.roomID, eventID: message.eventID),
                                terminalSearchFailure: terminalSearchFailure,
                                onOpen: { selectMessage(message) }
                            )
                            .id(ResultID.message(roomID: message.roomID, eventID: message.eventID))
                        }
                        if matrix.searchHasMore {
                            HStack {
                                Spacer()
                                loadMoreButton
                                Spacer()
                            }.padding(.vertical, m.sp16)
                        }
                    }
                }.padding(.horizontal, m.sp8).padding(.bottom, m.sp12)
            }
            .onChange(of: selectedResultID) { _, id in
                guard let id else { return }
                withAnimation(Motion.content) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func roomRow(_ room: ChatRoom, selected: Bool) -> some View {
        HStack(spacing: m.sp12) {
            if room.isDirect {
                AvatarView(name: room.name, size: m.avatar, matrix: matrix, source: room.avatarURL)
            } else {
                Image(systemName: room.isEncrypted ? "lock" : "number").font(m.font(.title)).frame(
                    width: m.avatar, height: m.avatar
                ).foregroundStyle(colors.textSecondary)
            }
            VStack(alignment: .leading, spacing: m.sp4) {
                Text(room.name).font(m.font(.body, .semibold)).lineLimit(1)
                if !room.topic.isEmpty {
                    Text(room.topic).font(m.font(.caption)).foregroundStyle(colors.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            if room.unread > 0 {
                Text("\(room.unread)").font(m.font(.caption, .semibold)).padding(.horizontal, m.sp8).padding(
                    .vertical, m.sp4
                ).background(colors.textSecondary.opacity(0.12), in: Capsule())
            }
            if selected { Image(systemName: "return").font(m.font(.caption)).foregroundStyle(colors.textSecondary) }
        }
    }

    private var loadMoreButton: some View {
        Button {
            loadMore()
        } label: {
            HStack(spacing: m.sp8) {
                if paging { DelayedProgress(interval: .searchLoading) }
                Text(paging ? "Loading…" : "Load more").font(m.font(.meta, .medium))
            }
        }.buttonStyle(.textLink).disabled(paging || searchBusy)
    }

    private var indexingTitle: String {
        switch matrix.searchIndexingState {
        case .stopping: return "Stopping…"
        case .stopped: return "Indexing stopped"
        case .completed: return "Recent messages indexed"
        case .running: return "Indexing recent messages…"
        case .idle: return startingIndex ? "Starting…" : "Looking for an older message?"
        }
    }
    private var indexingFooter: some View {
        HStack(alignment: .center, spacing: m.sp12) {
            Text(indexingTitle).font(m.font(.caption, .medium))
            Spacer(minLength: 0)
            if indexBusy { DelayedProgress().accessibilityLabel(indexingTitle) }
            if matrix.searchIndexingState.isBusy {
                Button(matrix.searchIndexingState == .stopping ? "Stopping…" : "Stop") {
                    [session = presentationSession] in
                    matrix.cancelSearchBackfill(sessionID: session)
                }.font(m.font(.caption, .medium)).disabled(matrix.searchIndexingState == .stopping)
            } else {
                Button(startingIndex ? "Starting…" : "Search older messages") { indexRecentHistory() }
                    .font(m.font(.caption, .medium)).disabled(indexBusy || matrix.isPreview)
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp12).background(colors.raised)
    }

    private func resultButton<Content: View>(
        id: ResultID, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content().padding(.horizontal, m.sp12).padding(.vertical, m.sp12).frame(
                maxWidth: .infinity, alignment: .leading
            )
            .background(
                id == selectedResultID ? colors.selection.opacity(appearance.isDark ? 0.65 : 1) : .clear,
                in: RoundedRectangle(cornerRadius: m.radius)
            )
            .contentShape(Rectangle())
        }.buttonStyle(.row).id(id)
    }

    private func move(_ direction: Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + direction + count) % count
    }

    private func activateSelected() {
        if let matrixLink, let onMatrixLink {
            close()
            onMatrixLink(matrixLink)
            return
        }
        guard count > 0 else { return }
        let index = min(selectedIndex, count - 1)
        if mode == .conversations { selectRoom(roomResults[index].id) } else { selectMessage(messages[index]) }
    }

    private func selectRoom(_ roomID: String) {
        onSelect(roomID)
        close()
    }
    private func selectMessage(_ message: ChatMessage) {
        if let onMessageSelect { onMessageSelect(message) } else { onSelect(message.roomID) }
        close()
    }
    private func close() {
        searchPresented = false
        searchRevision += 1
        if presentationSession == matrix.notificationSessionID { matrix.cancelSearch() }
        onClose()
    }

    private var searchOwner: SearchRequestOwner {
        SearchRequestOwner(sessionID: presentationSession, revision: searchRevision)
    }
    private var currentSearchOwner: SearchRequestOwner {
        SearchRequestOwner(sessionID: matrix.notificationSessionID, revision: searchRevision)
    }
    @MainActor private func queueSearch() {
        let submitted = request
        let owner = searchOwner
        Task { @MainActor in
            guard owner.isCurrent(currentSearchOwner, isPresented: searchPresented), submitted == request else {
                return
            }
            await runSearch(submitted, owner: owner)
        }
    }
    @MainActor private func runSearch(_ submitted: SearchRequest, owner: SearchRequestOwner) async {
        guard !Task.isCancelled, owner.isCurrent(currentSearchOwner, isPresented: searchPresented), submitted == request
        else { return }
        searchRevision += 1
        let continuation = searchOwner
        matrix.cancelSearch()
        activeRequest = submitted
        selectedIndex = 0
        paging = false
        error = nil
        guard submitted.mode == .messages, let sdkQuery = submitted.messageQuery.sdkQuery() else {
            searching = false
            return
        }
        searching = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, continuation.isCurrent(currentSearchOwner, isPresented: searchPresented),
                submitted == request
            else { return }
            try await matrix.searchMessages(query: sdkQuery, roomID: submitted.roomID)
            guard !Task.isCancelled, continuation.isCurrent(currentSearchOwner, isPresented: searchPresented),
                submitted == request
            else { return }
            searching = false
        } catch {
            guard !Task.isCancelled, continuation.isCurrent(currentSearchOwner, isPresented: searchPresented),
                submitted == request
            else { return }
            self.error = MatrixService.safeError(error)
            searching = false
        }
    }

    private func loadMore() {
        let submitted = request
        let owner = searchOwner
        guard !paging, !searchBusy, activeRequest == submitted,
            owner.isCurrent(currentSearchOwner, isPresented: searchPresented)
        else { return }
        paging = true
        error = nil
        Task { @MainActor in
            guard owner.isCurrent(currentSearchOwner, isPresented: searchPresented), submitted == request else {
                return
            }
            do {
                try await matrix.loadMoreSearch()
                guard owner.isCurrent(currentSearchOwner, isPresented: searchPresented), submitted == request else {
                    return
                }
                paging = false
            } catch {
                guard owner.isCurrent(currentSearchOwner, isPresented: searchPresented), submitted == request else {
                    return
                }
                self.error = MatrixService.safeError(error)
                paging = false
            }
        }
    }

    private func indexRecentHistory() {
        guard !indexBusy, !matrix.isPreview else { return }
        let session = presentationSession
        startingIndex = true
        error = nil
        Task { @MainActor in
            defer { startingIndex = false }
            guard matrix.notificationSessionID == session, !matrix.isPreview else { return }
            do { try await matrix.startSearchBackfill() } catch {
                guard matrix.notificationSessionID == session else { return }
                self.error = MatrixService.safeError(error)
            }
        }
    }
}

/// The search service applies the latest edit and drops deleted messages, so a hit shows as indexed.
private struct SearchMessageResultRow: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let hit: ChatMessage
    let selected: Bool
    let terminalSearchFailure: Bool
    var onOpen: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    private var currentMessage: ChatMessage? { terminalSearchFailure ? nil : hit }
    private var colors: AppColors { appearance.colors }
    private var roomName: String { matrix.rooms.first(where: { $0.id == hit.roomID })?.name ?? hit.roomID }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: m.sp12) {
                if let message = currentMessage {
                    AvatarView(name: message.senderName, size: m.avatar, matrix: matrix, source: message.avatarURL)
                } else {
                    Image(systemName: "text.bubble").font(m.font(.body)).foregroundStyle(colors.textSecondary).frame(
                        width: m.avatar, height: m.avatar)
                }
                VStack(alignment: .leading, spacing: m.sp4) {
                    HStack(spacing: m.sp8) {
                        if let message = currentMessage {
                            Text(message.senderName).font(m.font(.meta, .semibold))
                        }
                        Text(currentMessage == nil ? roomName : "in \(roomName)").font(m.font(.caption))
                            .foregroundStyle(colors.textSecondary).lineLimit(1)
                        Spacer()
                        if let message = currentMessage {
                            Text(message.timestamp, style: .date).font(m.font(.caption)).foregroundStyle(
                                colors.textSecondary)
                        }
                    }
                    if let message = currentMessage {
                        NativeMessageBody(
                            body: message.body, formattedBody: message.formattedBody, showsSpoilerControl: false
                        )
                        .lineLimit(2).multilineTextAlignment(.leading).allowsHitTesting(false)
                    } else {
                        Text("Preview unavailable")
                            .font(m.font(.meta)).foregroundStyle(colors.textSecondary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }.padding(.horizontal, m.sp12).padding(.vertical, m.sp12).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.row)
        .background(
            selected ? colors.selection.opacity(appearance.isDark ? 0.65 : 1) : .clear,
            in: RoundedRectangle(cornerRadius: m.radius)
        )
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
