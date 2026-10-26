import SwiftUI

/// The top bar's search: what's typed, whether its menu is open, and the search the main pane shows. Observable, so
/// typing redraws the bar and its menu, not the window.
@Observable @MainActor final class SearchBar {
    /// The coordinate space the field reports its frame in, and the menu drops from.
    nonisolated static let space = "SearchBar.window"
    var text = ""
    var menuOpen = false
    var selection = 0
    /// Bumped to put the cursor in the field: ⌘G and ⌘F.
    var focusRequests = 0
    var frame = CGRect.zero
    /// What the search results page shows.
    var submitted: MessageSearchQuery?

    func focus(text: String? = nil) {
        if let text { self.text = text }
        focusRequests += 1
    }

    func close() {
        menuOpen = false
        selection = 0
    }
}

/// The search field in the title bar. Typing opens `SearchMenu` below it; ↑ ↓ move through the menu, Return picks,
/// and Esc clears the field, then closes the menu.
struct SearchBarField: View {
    let bar: SearchBar
    let prompt: String
    let matrix: MatrixService
    let recents: [String]
    let visited: [String]
    let onPick: (SearchSuggestion) -> Void
    @FocusState private var focused: Bool
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    private var items: [SearchSuggestion] {
        SearchSuggestions.items(query: bar.text, recents: recents, rooms: matrix.rooms, visited: visited)
    }

    var body: some View {
        @Bindable var bar = bar
        let colors = appearance.colors
        HStack(spacing: m.sp8) {
            Image(systemName: "magnifyingglass").font(m.font(.body)).accessibilityHidden(true)
            TextField(prompt, text: $bar.text).textFieldStyle(.plain).font(m.font(.secondary)).focused($focused)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onSubmit {
                    let items = items
                    if items.indices.contains(bar.selection) { onPick(items[bar.selection]) }
                }
                .onExitCommand {
                    if bar.text.isEmpty { bar.close() } else { bar.text = "" }
                }
        }
        .padding(.horizontal, m.sp12).frame(height: m.row)
        .foregroundStyle(focused ? colors.textPrimary : colors.textBody)
        .background(
            focused ? colors.canvas : colors.textPrimary.opacity(appearance.isDark ? 0.19 : 0.08),
            in: RoundedRectangle(cornerRadius: m.radius)
        )
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(SearchBar.space))
        } action: {
            bar.frame = $0
        }
        .onChange(of: focused) { _, focused in
            if focused { bar.menuOpen = true } else { bar.close() }
        }
        .onChange(of: bar.menuOpen) { _, open in if !open { focused = false } }
        .onChange(of: bar.focusRequests) { _, _ in focused = true }
        .onChange(of: bar.text) { _, _ in
            bar.selection = 0
            if focused { bar.menuOpen = true }
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let count = items.count
        guard count > 0 else { return .ignored }
        bar.selection = (bar.selection + step + count) % count
        return .handled
    }
}

/// The menu that drops from the top bar's field while it has the cursor, as wide as the bar: recent searches,
/// matching conversations, and the search itself. It floats over the window, so nothing under it moves, and a click
/// below the title bar closes it.
struct SearchMenu: View {
    let bar: SearchBar
    let matrix: MatrixService
    let recents: [String]
    let visited: [String]
    /// The title bar's height; the bar stays clickable above it.
    let top: CGFloat
    let onPick: (SearchSuggestion) -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        ZStack(alignment: .topLeading) {
            if bar.menuOpen {
                let items = SearchSuggestions.items(
                    query: bar.text, recents: recents, rooms: matrix.rooms, visited: visited)
                // A button, not a tap gesture, so the click outside lands however the window was activated.
                Button(action: bar.close) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.row)
                    .focusable(false).accessibilityHidden(true).padding(.top, top)
                if !items.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element) { index, item in
                            row(item, selected: index == bar.selection)
                        }
                    }
                    .padding(m.sp8).frame(width: bar.frame.width)
                    .background(colors.overlay, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                    .elevation(.e2, cornerRadius: m.radiusLarge)
                    .offset(x: bar.frame.minX, y: bar.frame.maxY + m.sp4)
                }
            }
        }
        .animation(Motion.overlay, value: bar.menuOpen)
    }

    @ViewBuilder private func row(_ item: SearchSuggestion, selected: Bool) -> some View {
        switch item {
        case .search(let text):
            MenuRow(title: "Search for “\(text)”", selected: selected) {
                onPick(item)
            } icon: {
                Image(systemName: "magnifyingglass").font(m.font(.secondary))
            }
        case .recent(let text):
            MenuRow(title: text, selected: selected) {
                onPick(item)
            } icon: {
                Image(systemName: "clock.arrow.circlepath").font(m.font(.secondary))
            }
        case .conversation(let room):
            MenuRow(title: room.name, detail: conversationDetail(room, matrix), selected: selected) {
                onPick(item)
            } icon: {
                RoomIcon(room: room, matrix: matrix)
            }
        }
    }
}

/// The workspace a channel belongs to, so two "general"s tell apart.
@MainActor func conversationDetail(_ room: ChatRoom, _ matrix: MatrixService) -> String? {
    room.isDirect ? nil : matrix.workspaces.first { room.spaceIDs.contains($0.id) }?.name
}

/// A conversation's picture in a list: the person's photo for a direct message, a # or a lock for a channel.
struct RoomIcon: View {
    let room: ChatRoom
    let matrix: MatrixService
    var size: CGFloat?
    @Environment(\.metrics) private var m

    var body: some View {
        let side = size ?? m.avatarMedium
        if room.isDirect {
            AvatarView(name: room.name, size: side, matrix: matrix, source: room.avatarURL)
        } else {
            Image(systemName: room.isEncrypted ? "lock" : "number").font(m.font(side > m.avatarMedium ? .title : .body))
                .frame(width: side, height: side)
        }
    }
}

/// Slack's search results in the main pane: the query, tabs for messages, files, channels and people, and filters for
/// messages and files. A message or file opens where it was shared; a channel opens, or shows its invitation; a person
/// opens their profile.
struct SearchResultsView: View {
    enum Tab { case messages, files, channels, people }
    let matrix: MatrixService
    let bar: SearchBar
    var onOpenMessage: (ChatMessage) -> Void
    var onOpenRoom: (String) -> Void
    var onOpenProfile: (String, ChatUser?) -> Void
    @State private var tab = Tab.messages
    @State private var retry = 0
    @State private var activeRun: Run?
    @State private var searching = false
    @State private var paging = false
    @State private var startingIndex = false
    @State private var error: String?
    @State private var peopleQuery: String?
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    private struct Run: Hashable {
        let query: MessageSearchQuery
        let retry: Int
        let session: UUID
    }
    private var colors: AppColors { appearance.colors }
    private var query: MessageSearchQuery { bar.submitted ?? MessageSearchQuery("") }
    private var run: Run { Run(query: query, retry: retry, session: matrix.notificationSessionID) }
    private var messages: [ChatMessage] { activeRun == run ? matrix.searchResults : [] }
    private var searchBusy: Bool { searching || (activeRun == run && matrix.searchState == "loading") }
    private var indexBusy: Bool { startingIndex || matrix.searchIndexingState.isBusy }
    private var searchError: String? {
        error
            ?? (activeRun == run && matrix.searchState == "error"
                ? (matrix.searchErrorMessage ?? "Couldn’t search. Try again.") : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: m.sp8) {
                Image(systemName: "magnifyingglass").font(m.font(.title)).foregroundStyle(colors.textSecondary)
                Text(query.text.isEmpty ? "Search" : query.text).font(m.font(.title, .bold))
                    .foregroundStyle(colors.textPrimary).lineLimit(1).accessibilityAddTraits(.isHeader)
            }.padding(.horizontal, m.sp24).frame(height: m.paneHeader)
            TabBar(
                tabs: [
                    .init(value: Tab.messages, title: "Messages"), .init(value: Tab.files, title: "Files"),
                    .init(value: Tab.channels, title: "Channels"), .init(value: Tab.people, title: "People"),
                ], selection: $tab
            ).padding(.horizontal, m.sp24)
            Divider().overlay(colors.border)
            switch tab {
            case .messages: messagesTab
            case .files: filesTab
            case .channels: channelsTab
            case .people: peopleTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(colors.canvas)
        .task(id: run) { await search(run) }
        .onChange(of: matrix.searchIndexingState) { _, state in
            if state == .completed || state == .stopped { retry += 1 }
        }
        .onDisappear { matrix.cancelSearch() }
    }

    // MARK: Messages

    private var messagesTab: some View {
        VStack(spacing: 0) {
            filters.padding(.horizontal, m.sp24).padding(.vertical, m.sp12)
            messageResults.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(colors.border)
            indexingFooter
        }
    }

    private var filters: some View {
        HStack(spacing: m.sp8) {
            Menu {
                Button("Anyone") { bar.submitted?.senderID = nil }
                Divider()
                ForEach(senders) { person in Button(person.name) { bar.submitted?.senderID = person.id } }
            } label: {
                FilterChip(title: senderTitle, active: query.senderID != nil)
            }
            Menu {
                Button("Anywhere") { bar.submitted?.roomID = nil }
                Divider()
                ForEach(ConversationSwitcher.results(matrix.rooms, query: "", visited: []).prefix(20)) { room in
                    Button(room.name) { bar.submitted?.roomID = room.id }
                }
            } label: {
                FilterChip(
                    title: matrix.rooms.first { $0.id == query.roomID }.map { "In: \($0.name)" } ?? "In",
                    active: query.roomID != nil)
            }
            Menu {
                Button("Any time") { bar.submitted?.date = nil }
                Divider()
                ForEach(SearchDate.allCases, id: \.self) { date in
                    Button(date.rawValue) { bar.submitted?.date = date }
                }
            } label: {
                FilterChip(title: query.date?.rawValue ?? "Date", active: query.date != nil)
            }
            Button {
                bar.submitted?.mode = query.mode == .phrase ? .query : .phrase
            } label: {
                FilterChip(title: "Exact phrase", active: query.mode == .phrase, menu: false)
            }
            Spacer(minLength: 0)
            if searchBusy && !messages.isEmpty {
                DelayedProgress(interval: .searchLoading).accessibilityLabel("Searching")
            }
        }
        .menuStyle(.button).buttonStyle(.row).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
    }

    /// You, the people in these results and in the open conversation: who a From filter can name without a lookup.
    private var senders: [ChatUser] {
        var seen = Set<String>()
        let me = matrix.user.map { ChatUser(id: $0.id, name: "You") }
        let found = matrix.searchResults.map { ChatUser(id: $0.senderID, name: $0.senderName) } + matrix.members
        return
            ([me].compactMap { $0 }
            + found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            .filter { seen.insert($0.id).inserted }.prefix(20).map { $0 }
    }

    private var senderTitle: String {
        guard let id = query.senderID else { return "From" }
        return "From: " + (senders.first { $0.id == id }?.name ?? id)
    }

    @ViewBuilder private var messageResults: some View {
        if query.sdkQuery() == nil {
            EmptyStateView(symbol: "text.magnifyingglass", title: "Add words to search for")
        } else if messages.isEmpty && (searchBusy || activeRun != run) {
            SkeletonRows(interval: .searchLoading)
        } else if messages.isEmpty, let searchError {
            EmptyStateView(symbol: "exclamationmark.circle", title: searchError) {
                Button("Try again") { retry += 1 }
            }
        } else if messages.isEmpty {
            if indexBusy {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "Still indexing recent messages") {
                    if matrix.searchHasMore { loadMoreButton }
                }
            } else if matrix.searchHasMore {
                EmptyStateView(symbol: "text.magnifyingglass", title: "No matches yet") { loadMoreButton }
            } else {
                EmptyStateView(symbol: "magnifyingglass", title: "No matches")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let searchError {
                        HStack(spacing: m.sp8) {
                            InlineErrorView(message: searchError)
                            Button("Try again") { retry += 1 }.buttonStyle(.textLink).disabled(searchBusy || paging)
                        }.padding(.horizontal, m.sp24).padding(.top, m.sp12)
                    }
                    ForEach(messages) { message in
                        MessageResultRow(
                            matrix: matrix, message: message, query: query, action: { onOpenMessage(message) })
                        Divider().overlay(colors.border).padding(.horizontal, m.sp24)
                    }
                    if matrix.searchHasMore {
                        loadMoreButton.frame(maxWidth: .infinity).padding(.vertical, m.sp16)
                    }
                }
            }
        }
    }

    private var loadMoreButton: some View {
        Button("Load more", action: loadMore).buttonStyle(.textLink).font(m.font(.meta, .medium))
            .disabled(paging || searchBusy)
            // Beside the button, so it never moves when the spinner shows.
            .overlay(alignment: .leading) {
                if paging { DelayedProgress(interval: .searchLoading).offset(x: -m.sp24) }
            }
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
                    [session = matrix.notificationSessionID] in
                    matrix.cancelSearchBackfill(sessionID: session)
                }.font(m.font(.caption, .medium)).disabled(matrix.searchIndexingState == .stopping)
            } else {
                Button(startingIndex ? "Starting…" : "Search older messages", action: indexRecentHistory)
                    .font(m.font(.caption, .medium)).disabled(indexBusy || matrix.isPreview)
            }
        }
        .buttonStyle(.textLink).padding(.horizontal, m.sp24).padding(.vertical, m.sp12).background(colors.raised)
    }

    private func search(_ run: Run) async {
        matrix.cancelSearch()
        activeRun = run
        paging = false
        error = nil
        guard let sdkQuery = run.query.sdkQuery() else { return }
        searching = true
        do { try await matrix.searchMessages(query: sdkQuery, roomID: run.query.roomID) } catch {
            if !Task.isCancelled { self.error = MatrixService.safeError(error) }
        }
        if !Task.isCancelled { searching = false }
    }

    private func loadMore() {
        let current = run
        guard !paging, !searchBusy, activeRun == current else { return }
        paging = true
        error = nil
        Task { @MainActor in
            do { try await matrix.loadMoreSearch() } catch {
                if activeRun == current { self.error = MatrixService.safeError(error) }
            }
            if activeRun == current { paging = false }
        }
    }

    private func indexRecentHistory() {
        guard !indexBusy, !matrix.isPreview else { return }
        let session = matrix.notificationSessionID
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

    /// The hits that share a file: the index holds a file message's name as its text.
    private var filesTab: some View {
        let files = messages.filter { $0.attachment != nil }
        return VStack(spacing: 0) {
            filters.padding(.horizontal, m.sp24).padding(.vertical, m.sp12)
            if files.isEmpty && query.sdkQuery() != nil && (searchBusy || activeRun != run) {
                SkeletonRows(interval: .searchLoading)
            } else if files.isEmpty {
                EmptyStateView(symbol: "doc", title: "No files found") {
                    if matrix.searchHasMore { loadMoreButton }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files) { message in
                            let name = message.attachment?.name ?? message.body
                            FileRow(
                                tile: .file(FileKind(name: name, mimeType: message.attachment?.mimeType)), name: name,
                                caption: SharedContentMapping.caption(
                                    sender: message.senderName, room: matrix.rooms.first { $0.id == message.roomID },
                                    date: message.timestamp),
                                onOpen: { onOpenMessage(message) }
                            ) {
                                Button("View in conversation") { onOpenMessage(message) }
                            }
                        }
                        if matrix.searchHasMore {
                            loadMoreButton.frame(maxWidth: .infinity).padding(.vertical, m.sp16)
                        }
                    }.padding(.horizontal, m.sp12).padding(.vertical, m.sp8)
                }
            }
        }
    }

    // MARK: Channels and people

    @ViewBuilder private var channelsTab: some View {
        let rooms = ConversationSwitcher.results(matrix.rooms, query: query.text, visited: []).filter { !$0.isDirect }
        if rooms.isEmpty {
            EmptyStateView(symbol: "number", title: "No channels found")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rooms) { room in
                        ChannelResultRow(matrix: matrix, room: room) { onOpenRoom(room.id) }
                        Divider().overlay(colors.border).padding(.horizontal, m.sp24)
                    }
                }
            }
        }
    }

    @ViewBuilder private var peopleTab: some View {
        let people = matrix.people
        let results = peopleQuery == query.text ? people.results : []
        Group {
            if results.isEmpty && (people.searchState == "loading" || peopleQuery != query.text) {
                SkeletonRows(interval: .peopleLoading)
            } else if results.isEmpty && people.searchState == "error" {
                EmptyStateView(
                    symbol: "exclamationmark.circle", title: people.searchErrorMessage ?? "Couldn’t search. Try again.")
            } else if results.isEmpty {
                EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "No people found")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { person in
                            PersonRow(
                                name: person.name, userID: person.id, isYou: person.id == matrix.user?.id,
                                matrix: matrix, avatarSource: person.avatarURL
                            ) {
                                onOpenProfile(
                                    person.id,
                                    person.profileAvailable
                                        ? ChatUser(id: person.id, name: person.name, avatarURL: person.avatarURL) : nil)
                            }
                        }
                    }.padding(.horizontal, m.sp12).padding(.vertical, m.sp8)
                }
            }
        }
        .task(id: query.text) {
            peopleQuery = query.text
            await people.search(query.text)
        }
        .onDisappear { people.cancelSearch() }
    }
}

/// A search hit as Slack lists it: where it was said, then who said it and when, and the words that matched.
private struct MessageResultRow: View {
    /// Characters of a long message shown before its first match.
    private static let lead = 32
    let matrix: MatrixService
    let message: ChatMessage
    let query: MessageSearchQuery
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let room = matrix.rooms.first { $0.id == message.roomID }
        Button(action: action) {
            VStack(alignment: .leading, spacing: m.sp8) {
                HStack(spacing: m.sp4) {
                    Image(systemName: room?.isDirect == true ? "person" : "number")
                    Text(room?.name ?? message.roomID)
                }.font(m.font(.meta, .semibold)).foregroundStyle(colors.textSecondary).lineLimit(1)
                HStack(alignment: .top, spacing: m.sp8) {
                    AvatarView(name: message.senderName, size: m.avatar, matrix: matrix, source: message.avatarURL)
                    VStack(alignment: .leading, spacing: m.sp2) {
                        HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                            Text(message.senderName).font(m.font(.body, .bold)).foregroundStyle(colors.textPrimary)
                            Text(message.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                .font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                        }.lineLimit(1)
                        Text(snippet(colors)).font(m.font(.body)).foregroundStyle(colors.textBody).lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, m.sp24).padding(.vertical, m.sp12).frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? colors.hover : .clear)
        }
        .buttonStyle(.row).onHover { hovering = $0 }
    }

    /// The message from a little before its first match, so the match shows in three lines.
    private func snippet(_ colors: AppColors) -> AttributedString {
        // Blank lines would spend the three lines on nothing.
        var body = message.body.replacing(#/\n\s*\n/#, with: "\n")
        if let first = query.highlights(in: body).first,
            body.distance(from: body.startIndex, to: first.lowerBound) > Self.lead * 2
        {
            let from = body.index(first.lowerBound, offsetBy: -Self.lead)
            body = "…" + body[(body[..<from].lastIndex(where: \.isWhitespace).map(body.index(after:)) ?? from)...]
        }
        var text = AttributedString(body)
        for range in query.highlights(in: body) {
            if let range = Range(range, in: text) { text[range].backgroundColor = colors.highlight }
        }
        return text
    }
}

/// A channel in search results: its name and what it's about. One you were invited to says so.
private struct ChannelResultRow: View {
    let matrix: MatrixService
    let room: ChatRoom
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Button(action: action) {
            HStack(spacing: m.sp12) {
                RoomIcon(room: room, matrix: matrix, size: m.avatar).foregroundStyle(colors.textSecondary)
                VStack(alignment: .leading, spacing: m.sp2) {
                    HStack(spacing: m.sp8) {
                        Text(room.name).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
                        if room.membership == "invite" { TagLabel(text: "Invited") }
                    }
                    Text(room.topic.isEmpty ? "\(room.memberCount) members" : room.topic).font(m.font(.meta))
                        .foregroundStyle(colors.textSecondary)
                }.lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, m.sp24).frame(height: m.personRow + m.sp8)
            .background(hovering ? colors.hover : .clear)
        }
        .buttonStyle(.row).onHover { hovering = $0 }
    }
}
