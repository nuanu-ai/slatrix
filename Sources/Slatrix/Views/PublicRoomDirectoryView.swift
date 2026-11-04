import SwiftUI

/// Browse channels, a page in place of the conversation: a workspace's channels, or the server's public directory.
struct PublicRoomDirectoryView: View {
    private static let membersWidth: CGFloat = 52
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let service: PublicRoomDirectoryService
    /// Lists this workspace's channels; nil browses the server's public directory.
    var workspace: Workspace? = nil
    var onResolve: (MatrixLinkResolution) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var query = ""
    @State private var hovered: String?
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

    var body: some View {
        VStack(spacing: 0) {
            controls
            directoryContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(colors.canvas)
        .onAppear {
            owner = context
            isPresented = true
            searchFocused = true
        }
        .onChange(of: context) { _, next in
            // Another account: start over with its channels.
            service.close()
            openedContext = nil
            owner = next
        }
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
        .task(id: request) { await search(request) }
    }

    private var controls: some View {
        HStack(spacing: m.sp8) {
            Image(systemName: "magnifyingglass").foregroundStyle(colors.textSecondary)
            TextField("Search by name or topic", text: $query).textFieldStyle(.plain).font(m.font(.reading))
                .focused($searchFocused).accessibilityLabel("Search channels")
            if searching { DelayedProgress().accessibilityLabel("Searching") }
            if !query.isEmpty {
                IconButton(symbol: "xmark.circle.fill", label: "Clear search", role: .body) {
                    query = ""
                    searchFocused = true
                }
            }
        }.padding(.horizontal, m(14)).frame(height: m(36))
            .background(colors.control, in: Capsule()).elevation(.e1, cornerRadius: m(18))
            .padding(.horizontal, m.sp24).padding(.top, m.sp4).padding(.bottom, m.sp8)
    }

    @ViewBuilder private var directoryContent: some View {
        if context.preview || context.accountID == nil {
            EmptyStateView(symbol: "globe", title: "Sign in to browse channels")
        } else if entries.isEmpty, let displayedError {
            EmptyStateView(symbol: "exclamationmark.circle", title: displayedError) {
                Button("Try again", action: retry).disabled(searching)
            }
        } else if entries.isEmpty && searching {
            SkeletonRows().padding(.horizontal, m.sp24).padding(.top, m.sp16)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if entries.isEmpty && !request.query.isEmpty && !service.hasMore {
            EmptyStateView(symbol: "magnifyingglass", title: "No channels match \u{201C}\(request.query)\u{201D}")
        } else if entries.isEmpty {
            EmptyStateView(symbol: "number", title: workspace == nil ? "No public channels" : "No channels yet") {
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
                        }.padding(.horizontal, m.sp12).padding(.vertical, m.sp16)
                    }
                    ForEach(entries) { directoryRow($0) }
                    if service.hasMore {
                        HStack {
                            Spacer()
                            loadMoreButton
                            Spacer()
                        }.padding(.vertical, m.sp20)
                    }
                }.padding(.horizontal, m.sp12).padding(.bottom, m.sp12)
            }
        }
    }

    private func directoryRow(_ entry: PublicDirectoryRoom) -> some View {
        let joined = isJoined(entry.id)
        let opens = joined || entry.canJoin
        return HStack(spacing: m.sp12) {
            Image(systemName: entry.joinRule == .invite ? "lock" : "number").font(m.font(.reading))
                .foregroundStyle(colors.textSecondary).frame(width: m(20))
            VStack(alignment: .leading, spacing: m(1)) {
                HStack(spacing: m.sp8) {
                    Text(entry.displayName).font(m.font(.reading, .semibold)).foregroundStyle(colors.textPrimary)
                    if joined {
                        HStack(spacing: m(3)) {
                            Image(systemName: "checkmark").foregroundStyle(colors.accent)
                            Text("Joined")
                        }.font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                    }
                }.lineLimit(1)
                // A space until there is a topic, so every row keeps its height.
                Text(entry.topic ?? (workspace == nil ? entry.alias ?? " " : " ")).font(m.font(.body))
                    .foregroundStyle(colors.textSecondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if resolvingID == entry.id {
                DelayedProgress()
            } else if hovered == entry.id && !joined && entry.canJoin {
                Button("Join") { review(entry) }.buttonStyle(.primary).controlSize(.small)
                    .accessibilityLabel("Join \(entry.displayName)")
            }
            HStack(spacing: m(5)) {
                Image(systemName: "person.2")
                Text(entry.joinedMembers.formatted())
            }.font(m.font(.body)).foregroundStyle(colors.textSecondary)
                .frame(width: m(Self.membersWidth), alignment: .trailing)
                .accessibilityLabel("\(entry.joinedMembers) \(entry.joinedMembers == 1 ? "member" : "members")")
        }
        .padding(.horizontal, m.sp12).frame(height: m(52))
        .background(hovered == entry.id && opens ? colors.hover : .clear, in: RoundedRectangle(cornerRadius: m.radius))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? entry.id : hovered == entry.id ? nil : hovered }
        .onTapGesture { if opens { review(entry) } }
        .help(opens ? "" : ruleLabel(entry.joinRule))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(opens ? .isButton : [])
        .accessibilityAction { if opens { review(entry) } }
    }

    private var loadMoreButton: some View {
        Button(action: loadMore) {
            HStack(spacing: m.sp8) {
                if service.isLoading { DelayedProgress() }
                Text(service.isLoading ? "Loading…" : "Load more")
            }.font(m.font(.subheadline, .medium))
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
}
