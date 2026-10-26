import SwiftUI

struct PublicRoomDirectoryView: View {
    private static let size = CGSize(width: 720, height: 620)
    private static let searchHeight: CGFloat = 40
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let service: PublicRoomDirectoryService
    /// Lists this workspace's channels; nil browses the server's public directory.
    var workspace: Workspace? = nil
    var onResolve: (MatrixLinkResolution) -> Void
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var query = ""
    @State private var retryRevision = 0
    @State private var owner: Context?
    @State private var openedContext: Context?
    @State private var activeRequest: SearchRequest?
    @State private var isPresented = false
    @State private var resolvingID: String?
    @State private var resolutionRequest = UUID()
    @State private var failedLoadingMore = false
    @State private var reviewFailed = false
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private struct Context: Hashable {
        let session: UUID
        let accountID: String?
        let preview: Bool
    }
    private struct SearchRequest: Hashable {
        let context: Context
        let query: String
        let retry: Int
    }
    private var context: Context {
        Context(session: matrix.notificationSessionID, accountID: matrix.user?.id, preview: matrix.isPreview)
    }
    private var request: SearchRequest {
        SearchRequest(
            context: context, query: query.trimmingCharacters(in: .whitespacesAndNewlines), retry: retryRevision)
    }
    private var current: Bool { isPresented && owner == context && context.accountID != nil && !context.preview }
    private var colors: AppColors { appearance.colors }
    private var entries: [PublicDirectoryRoom] { activeRequest == request ? service.entries : [] }
    private var searching: Bool { current && (activeRequest != request || service.isLoading) }
    private var displayedError: String? { error ?? (activeRequest == request ? service.errorMessage : nil) }
    private var serverName: String {
        matrix.homeserverURL.flatMap { URL(string: $0)?.host } ?? matrix.homeserverURL ?? "your homeserver"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(colors.border)
            directoryContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.sheetSize(width: Self.size.width, height: Self.size.height).background(colors.canvas).foregroundStyle(
            colors.textBody
        )
        .onAppear {
            owner = context
            isPresented = true
            searchFocused = true
        }
        .onChange(of: context) { _, _ in close() }
        .onChange(of: query) { _, _ in
            resolutionRequest = UUID()
            resolvingID = nil
            error = nil
        }
        .onDisappear {
            isPresented = false
            resolutionRequest = UUID()
            service.close()
        }
        .onExitCommand(perform: close)
        .task(id: request) { await search(request) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: m.sp16) {
            HStack(alignment: .top, spacing: m.sp16) {
                VStack(alignment: .leading, spacing: m.sp8) {
                    Text("Browse channels").font(m.font(.header, .bold)).foregroundStyle(
                        colors.textPrimary)
                    Text(workspace?.name ?? serverName).font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                IconButton(symbol: "xmark", label: "Close", role: .secondary, action: close)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: m.sp8) {
                Image(systemName: "magnifyingglass").foregroundStyle(colors.textSecondary)
                TextField("Search by channel name or topic", text: $query).textFieldStyle(.plain).font(
                    m.font(.body)
                ).focused($searchFocused)
                    .accessibilityLabel("Search channels")
                if searching { DelayedProgress().accessibilityLabel("Searching") }
                if !query.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: "Clear search", role: .secondary) {
                        query = ""
                        searchFocused = true
                    }
                }
            }.padding(.horizontal, m.sp12).frame(height: m(Self.searchHeight)).background(
                colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge)
            )
            .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
        }.padding(m.sp24)
    }

    @ViewBuilder private var directoryContent: some View {
        if context.preview || context.accountID == nil {
            EmptyStateView(symbol: "globe", title: "Sign in to browse channels")
        } else if entries.isEmpty, let displayedError {
            EmptyStateView(symbol: "exclamationmark.circle", title: displayedError) {
                Button("Try again", action: retry).disabled(searching)
            }
        } else if entries.isEmpty && searching {
            SkeletonRows()
        } else if entries.isEmpty {
            EmptyStateView(
                symbol: workspace == nil ? "globe" : "number",
                title: request.query.isEmpty
                    ? (workspace == nil ? "No public channels" : "No channels yet") : "No channels found"
            ) {
                if service.hasMore { loadMoreButton }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let displayedError {
                        VStack(alignment: .leading, spacing: m.sp8) {
                            InlineErrorView(message: displayedError)
                            if !reviewFailed {
                                Button(failedLoadingMore ? "Retry loading more" : "Try again", action: retry)
                                    .buttonStyle(.textLink).disabled(searching)
                            }
                        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16)
                    }
                    ForEach(entries) { entry in
                        directoryRow(entry)
                        Divider().overlay(colors.border).padding(.leading, m.sp24 + m.avatar + m.sp12)
                    }
                    if service.hasMore {
                        HStack {
                            Spacer()
                            loadMoreButton
                            Spacer()
                        }.padding(.vertical, m.sp20)
                    }
                }.padding(.bottom, m.sp12)
            }
        }
    }

    private func directoryRow(_ entry: PublicDirectoryRoom) -> some View {
        let joined = isJoined(entry.id)
        return HStack(alignment: .top, spacing: m.sp12) {
            AvatarView(name: entry.displayName, size: m.avatar, matrix: matrix, source: entry.avatarURL)
            VStack(alignment: .leading, spacing: m.sp8) {
                Text(entry.displayName).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
                    .lineLimit(2).help(entry.displayName)
                // A workspace's own channels need no address unless they have a readable one.
                if workspace == nil || entry.alias != nil {
                    Text(entry.alias ?? entry.id).font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                        .help(entry.alias ?? entry.id)
                }
                if let topic = entry.topic, !topic.isEmpty {
                    Text(topic).font(m.font(.meta)).foregroundStyle(colors.textSecondary).lineLimit(2)
                }
                HStack(spacing: m.sp12) {
                    Label(
                        "\(entry.joinedMembers.formatted()) \(entry.joinedMembers == 1 ? "member" : "members")",
                        systemImage: "person.2")
                    if joined {
                        Text("Joined")
                    } else if workspace == nil || !entry.canJoin {
                        Text(ruleLabel(entry.joinRule))
                    }
                }.font(m.font(.caption)).foregroundStyle(colors.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if joined || entry.canJoin {
                Button {
                    review(entry)
                } label: {
                    HStack(spacing: m.sp8) {
                        if resolvingID == entry.id { DelayedProgress() }
                        Text(joined ? "Open" : "Join")
                    }.font(m.font(.meta, .medium))
                }.buttonStyle(.secondary).disabled(!current || searching || resolvingID != nil)
                    .accessibilityLabel("\(joined ? "Open" : "Join") \(entry.displayName)")
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadMoreButton: some View {
        Button(action: loadMore) {
            HStack(spacing: m.sp8) {
                if service.isLoading { DelayedProgress() }
                Text(service.isLoading ? "Loading…" : "Load more")
            }.font(m.font(.meta, .medium))
        }.buttonStyle(.textLink).disabled(!current || searching || resolvingID != nil)
    }

    private func isJoined(_ roomID: String) -> Bool {
        matrix.rooms.contains { $0.id == roomID && $0.membership == "join" }
            || matrix.workspaces.contains { $0.id == roomID }
    }

    private func ruleLabel(_ rule: PublicDirectoryJoinRule) -> String {
        switch rule {
        case .publicRoom: "Public"
        case .knock: "Request to join"
        case .restricted: "Restricted"
        case .knockRestricted: "Restricted · request to join"
        case .invite: "Invite only"
        case .unknown: ""
        }
    }

    @MainActor private func search(_ submitted: SearchRequest) async {
        guard current, submitted == request else { return }
        resolutionRequest = UUID()
        resolvingID = nil
        error = nil
        failedLoadingMore = false
        reviewFailed = false
        do {
            if openedContext != submitted.context {
                try matrix.openPublicDirectory(spaceID: workspace?.id)
                openedContext = submitted.context
            }
            if !submitted.query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, current, submitted == request else { return }
            activeRequest = submitted
            await service.search(query: submitted.query)
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, current, submitted == request else { return }
            activeRequest = submitted
            self.error = MatrixService.safeError(error)
        }
    }

    private func retry() {
        guard current, !searching else { return }
        if failedLoadingMore && service.hasMore { loadMore() } else { retryRevision += 1 }
    }

    private func loadMore() {
        guard current, !searching, resolvingID == nil, service.hasMore else { return }
        let submitted = request
        let scope = service.scopeID
        error = nil
        failedLoadingMore = true
        reviewFailed = false
        Task { @MainActor in
            guard current, submitted == request, service.scopeID == scope else { return }
            await service.loadMore()
            guard current, submitted == request, service.scopeID == scope else { return }
            if service.errorMessage == nil { failedLoadingMore = false }
        }
    }

    private func review(_ entry: PublicDirectoryRoom) {
        guard current, !searching, resolvingID == nil, isJoined(entry.id) || entry.canJoin else { return }
        let token = UUID()
        let submitted = request
        let scope = service.scopeID
        resolutionRequest = token
        resolvingID = entry.id
        error = nil
        reviewFailed = false
        Task { @MainActor in
            guard current, request == submitted, service.scopeID == scope, resolutionRequest == token else { return }
            do {
                let resolution = try await matrix.resolvePublicDirectoryEntry(roomID: entry.id, scopeID: scope)
                guard !Task.isCancelled, current, request == submitted, service.scopeID == scope,
                    resolutionRequest == token
                else { return }
                guard resolution.sessionID == context.session, resolution.accountID == context.accountID else { return }
                resolvingID = nil
                isPresented = false
                resolutionRequest = UUID()
                onResolve(resolution)
            } catch is CancellationError {
                if current, request == submitted, resolutionRequest == token { resolvingID = nil }
            } catch {
                guard current, request == submitted, service.scopeID == scope, resolutionRequest == token else {
                    return
                }
                resolvingID = nil
                reviewFailed = true
                self.error = MatrixService.safeError(error)
            }
        }
    }

    private func close() {
        isPresented = false
        resolutionRequest = UUID()
        service.close()
        onClose()
    }
}
