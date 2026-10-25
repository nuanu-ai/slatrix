import AppKit
import Combine
import QuickLook
import SwiftUI

enum AppRoute: String, CaseIterable {
    case home, directMessages, activity, files, saved, threads, drafts, directory
    var title: String {
        switch self {
        case .home: "Home"
        case .directMessages: "DMs"
        case .activity: "Activity"
        case .files: "Files"
        case .saved: "Later"
        case .threads: "Threads"
        case .drafts: "Drafts"
        case .directory: "People"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .directMessages: "bubble.left.and.bubble.right"
        case .activity: "bell"
        case .files: "doc.on.doc"
        case .saved: "bookmark"
        case .threads: "bubble.left"
        case .drafts: "paperplane"
        case .directory: "person.crop.square"
        }
    }
}

struct RootView: View {
    let matrix: MatrixService
    @ObservedObject private var platform = PlatformIntegration.shared
    @ObservedObject private var updater = AppUpdater.shared
    @EnvironmentObject var appearance: AppearanceStore
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.metrics) private var m
    @State private var route = AppRoute.home
    @State private var workspaceID: String?
    @State private var workspaceInitialized = false
    @State private var pendingRoomID: String?
    @State private var preferredRoomID: String?
    @State private var sidebarSearch = ""
    @AppStorage("layout.sidebarWidth") private var preferredSidebarWidth = 280.0
    @AppStorage("layout.sidebarHidden") private var sidebarHidden = false
    /// The dragged thread and details pane width at 100% zoom; 0 until dragged, for each pane's own width.
    @AppStorage("layout.paneWidth") private var preferredPaneWidth = 0.0
    @State private var resizingPaneWidth: CGFloat?
    /// Unscaled, like the stored preference: SidebarLayout works at 100% zoom.
    @State private var resizingSidebarWidth: CGFloat?
    @State private var availableContentWidth: CGFloat = 1_440
    /// Preferences, ⌘K and the shortcuts list, shown in the window like Slack's. Not read by this body, so opening
    /// one re-renders only the modal host, not the whole window.
    @State private var modals = InWindowModal()
    @State private var publicDirectory: PublicDirectorySelection?
    @State private var lastMessageReaction: MessageActionTarget?
    @State private var showRecovery = false
    @State private var creation: CreationKind?
    @State private var inviteTargetRoomID: String?
    @State private var person: ProfileSelection?
    @State private var roomDetails: DetailsSelection?
    @State private var roomNotifications: DetailsSelection?
    @State private var forwarding: ForwardSelection?
    @State private var mediaCaption: CaptionSelection?
    @State private var matrixJoin: MatrixJoinSelection?
    @State private var pendingMatrixLink: PendingMatrixLink?
    @State private var matrixLinkTask: Task<Void, Never>?
    @State private var infoOpen = false
    @State private var showPins = false
    @State private var pinPermissionRoomID: String?
    @State private var pinPermission = false
    @State private var threadRoot: ChatMessage?
    @State private var navigationGeneration = UUID()
    @State private var composerGeneration = UUID()
    @State private var composerStateIdentity: ComposerIdentity?
    @State private var threadReadyID: String?
    @State private var openingThreadID: String?
    @State private var unreadResumeEventID: String?
    @State private var threadLoadError: String?
    @State private var pendingThreadOpen: ThreadOpenRequest?
    @State private var threadOpenTask: Task<Void, Never>?
    @State private var threadOpenError: String?
    @State private var replyTarget: MessageReplyTarget?
    @State private var replyOpening = false
    @State private var replyError: String?
    @State private var editTarget: MessageEditTarget?
    @State private var editActionTarget: MessageActionTarget?
    @State private var editText = ""
    @State private var drafts = ComposerDrafts()
    @StateObject private var previews = AttachmentPreviewController()
    @StateObject private var attachmentDrafts = AttachmentDraftController()
    @State private var invitationResponseID: String?
    @State private var navigationNotice: String?
    @State private var sendingComposers: [String: Bool] = [:]
    @State private var saved: [SavedMessageReference] = []
    @State private var localAccess: ProtectedLocalStateAccess?
    @State private var localRevision: UInt64 = 0
    @State private var localLoadIdentity: ComposerIdentity?
    @State private var localTransitionTask: Task<Void, Never>?
    @State private var localSaveTask: Task<Void, Never>?
    @State private var localGeneration = UUID()
    @State private var localReady = false
    @State private var localError: String?
    @State private var bootstrapping = true
    @State private var history: [String] = []
    @State private var historyIndex = -1
    @State private var logoutConfirmation = false
    @StateObject private var logoutRecovery = LogoutRecoveryController()
    @State private var visibleBottomRoomID: String?
    @State private var threadReadViewport = ThreadReadViewport()
    @State private var windowCanRead = false
    @State private var readHold = ReadStateHold()
    private var colors: AppColors { appearance.colors }
    private static let threadPaneWidth: CGFloat = 380
    private static let titleBarHeight: CGFloat = 40
    private static let windowButtonsWidth: CGFloat = 72
    private static let searchWidth: CGFloat = 648
    private static let infoPaneWidth: CGFloat = 336
    /// The thread or details pane width at 100% zoom, nil when it covers the conversation.
    private var inspectorWidth: CGFloat? {
        guard room != nil, threadRoot != nil || infoOpen else { return nil }
        return SidebarLayout.paneWidth(
            preferred: resizingPaneWidth ?? CGFloat(preferredPaneWidth),
            ideal: threadRoot != nil ? Self.threadPaneWidth : Self.infoPaneWidth,
            availableWidth: availableContentWidth / m.zoom)
    }
    /// Pane width plus its divider, at 100% zoom.
    private var occupiedInspectorWidth: CGFloat { inspectorWidth.map { $0 + SidebarLayout.handleWidth } ?? 0 }
    private var sidebarListWidth: CGFloat {
        m(
            SidebarLayout.effective(
                preferred: resizingSidebarWidth ?? SidebarLayout.validatedPreferred(preferredSidebarWidth),
                availableWidth: availableContentWidth / m.zoom, inspectorWidth: occupiedInspectorWidth))
    }
    private var layoutMeasurement: some View {
        GeometryReader { geometry in
            Color.clear.onAppear { availableContentWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in availableContentWidth = width }
        }
    }

    private var room: ChatRoom? { shownRoom(matrix, workspaceID: workspaceID) }
    /// Opened at its unread line, from the cache or at the line from the server.
    private var isResumingUnread: Bool {
        unreadResumeEventID != nil && (matrix.focusedEventID == nil || unreadResumeEventID == matrix.focusedEventID)
    }
    private var draftAddresses: Set<AttachmentDraftAddress> {
        guard localReady, composerStateIdentity == composerIdentity else { return [] }
        return drafts.addresses.union(attachmentDrafts.queues.filter { !$0.value.isEmpty }.keys)
            .union(attachmentDrafts.files.filter { !$0.value.isEmpty }.keys)
    }
    private var draftRoomIDs: Set<String> { Set(draftAddresses.map(\.roomID)) }
    private var savedIDs: Set<String> { Set(saved.map(\.id)) }
    private var currentWorkspaceName: String { matrix.workspaces.first { $0.id == workspaceID }?.name ?? "Slatrix" }
    private struct ComposerIdentity: Equatable {
        var userID: String?
        var isPreview: Bool
        var sessionID: UUID
    }
    private struct ComposerContext {
        var generation: UUID
        var identity: ComposerIdentity
    }
    private struct ThreadOpenRequest: Identifiable {
        let id = UUID()
        let message: ChatMessage
        let owner: ComposerIdentity
        let selection: UUID
        let navigation: UUID
        let workspace: String?
        let informationVisible: Bool
        let sourceRoute: AppRoute
        let selectedRoomID: String?
        let pinsVisible: Bool
    }
    private struct ProfileSelection: Identifiable {
        var id: String
        var fallback: ChatUser?
    }
    private struct DetailsSelection: Identifiable { var id: String }
    private struct ForwardSelection: Identifiable {
        let target: MessageActionTarget
        let navigation: UUID
        let workspaceID: String?
        var id: UUID { target.id }
    }
    private struct CaptionSelection: Identifiable {
        let target: MessageActionTarget
        let navigation: UUID
        let workspaceID: String?
        var id: UUID { target.id }
    }
    private struct MatrixJoinSelection: Identifiable {
        let request: MatrixRoomJoinRequest
        let navigation: UUID
        var id: UUID { request.id }
    }
    private struct PendingMatrixLink {
        enum Source {
            case url(URL)
            case resolved(MatrixLinkResolution)
        }
        let id = UUID()
        let source: Source
        let accountID: String
        let session: UUID
        let navigation: UUID
        let route: AppRoute
        let workspaceID: String?
    }
    private struct PublicDirectorySelection: Identifiable {
        let id = UUID()
        let accountID: String
        let session: UUID
        let navigation: UUID
        let route: AppRoute
        let workspaceID: String?
    }
    private var composerIdentity: ComposerIdentity {
        ComposerIdentity(userID: matrix.user?.id, isPreview: matrix.isPreview, sessionID: matrix.notificationSessionID)
    }
    private var composerContext: ComposerContext {
        ComposerContext(generation: composerGeneration, identity: composerIdentity)
    }
    private var editContext: MessageEditTarget.Context {
        MessageEditTarget.Context(
            sessionID: matrix.notificationSessionID, userID: matrix.user?.id, roomID: matrix.selectedRoomID,
            timelineID: matrix.timelineSelectionID, threadID: threadRoot?.eventID, readyThreadID: threadReadyID)
    }
    private var hasPresentedSheet: Bool {
        publicDirectory != nil || showRecovery || creation != nil
            || person != nil || roomDetails != nil || roomNotifications != nil || forwarding != nil
            || mediaCaption != nil || matrixJoin != nil || previews.url != nil || logoutConfirmation
            || logoutRecovery.request != nil || logoutRecovery.isBusy
    }
    private var hasNativeModal: Bool { ReadInputs.hasNativeModal }

    /// Every modal, for actions that must wait for all of them; read outside the body only.
    private var hasModal: Bool { hasPresentedSheet || modals.current != nil }

    var body: some View {
        ModalHost(modals: modals, onClose: closeModal) {
            windowContent
        } modal: { kind in
            modal(kind).environmentObject(appearance)
        }
    }

    @ViewBuilder private func modal(_ kind: InWindowModal.Kind) -> some View {
        switch kind {
        case .preferences:
            PreferencesView(
                matrix: matrix, onClose: closeModal,
                onLogout: {
                    closeModal()
                    logoutConfirmation = true
                },
                // A sheet over a modal would inherit its disabled window, so the modal steps aside first.
                onRecovery: {
                    closeModal()
                    showRecovery = true
                }
            ).onAppear { Performance.finishOnScreen(.preferencesOpen) }
        case .search(let messages, let roomID):
            QuickSwitcherView(
                matrix: matrix,
                onSelect: {
                    selectRoom($0)
                    closeModal()
                }, onClose: closeModal,
                onMessageSelect: { message in
                    closeModal()
                    selectRoom(message.roomID, record: true, eventID: message.eventID)
                }, initiallyMessages: messages, initialRoomID: roomID, onMatrixLink: enqueueMatrixLink
            ).onAppear { Performance.finishOnScreen(.searchOpen) }
        case .shortcuts: KeyboardShortcutsView(onClose: closeModal)
        }
    }

    private func closeModal() {
        guard modals.current != nil else { return }
        modals.current = nil
        // What a modal held back: a notification to open, and messages the reader can see again.
        openPendingNotification()
        Task {
            await acknowledgeVisibleTimeline()
            await acknowledgeVisibleThread()
        }
    }

    private var windowContent: some View {
        readAwareContent
            .disabled(logoutRecovery.isBusy)
            .overlay {
                if logoutRecovery.isBusy {
                    VStack(spacing: m.sp12) {
                        ProgressView()
                        Text("Signing out…").font(m.font(.secondary))
                    }
                    .padding(m.sp24).background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                }
            }
            .environmentObject(previews)
            .quickLookPreview(Binding(get: { previews.url }, set: previews.presentationChanged))
            .background(PreviewInvalidation(matrix: matrix, previews: previews))
            .environment(\.openURL, OpenURLAction(handler: handleOpenURL))
            .background(layoutMeasurement)
    }

    private var readAwareContent: some View {
        notificationAwareContent
            .onAppear {
                previews.setSession(matrix.notificationSessionID)
                SlatrixTermination.flush = {
                    try await flushLocalData()
                    await attachmentDrafts.close()
                }
                windowCanRead = platform.conversationWindowIsVisible
            }
            .onReceive(readWindowChanges) { notification in
                if notification.name == NSWindow.willBeginSheetNotification {
                    windowCanRead = false
                } else {
                    DispatchQueue.main.async {
                        windowCanRead = platform.conversationWindowIsVisible
                        if notification.name == NSWindow.didEndSheetNotification { openPendingNotification() }
                    }
                }
            }
            .background(
                ReadTracking(
                    matrix: matrix, inputs: readInputs, onReadContext: { readHold.observe($0) },
                    onThreadIdentity: { threadReadViewport.observe($0) },
                    acknowledgeTimeline: acknowledgeVisibleTimeline, acknowledgeThread: acknowledgeVisibleThread))
    }

    private var notificationAwareContent: some View {
        observedContent
            .onReceive(platform.$pendingNotification) { target in
                if target != nil { Task { @MainActor in openPendingNotification() } }
            }
            .onChange(of: hasPresentedSheet) { _, shown in
                if !shown { Task { @MainActor in openPendingNotification() } }
            }
            .onChange(of: matrix.verification.isPresented, initial: true) { _, shown in
                if shown { closeModal() }
                if !shown { Task { @MainActor in openPendingNotification() } }
            }
            .onChange(of: navigationGeneration) { _, generation in
                if let request = pendingMatrixLink, request.navigation != generation { cancelMatrixLink() }
            }
    }

    private var roomObservedContent: some View {
        presentedContent
            .background(RoomListWatcher(matrix: matrix, onRooms: roomsChanged, onWorkspaces: settleWorkspace))
            .onChange(of: workspaceID) { _, id in
                Performance.finishOnScreen(.workspaceSwitch)
                cancelStaleThreadOpen()
                cancelStaleForward()
                cancelStaleCaption()
                if let request = pendingMatrixLink, request.workspaceID != id { cancelMatrixLink() }
                if let target = editTarget, room?.id != target.message.roomID { cancelCurrentEdit() }
                if let target = replyTarget, room?.id != target.message.roomID { cancelReply() }
                if matrix.user != nil {
                    UserDefaults.standard.set(id ?? WorkspaceRail.allToken, forKey: "workspace.\(storageKey)")
                }
                if route == .home && pendingRoomID == nil && invitationResponseID == nil && room == nil {
                    matrix.setMessageActionThread(rootID: nil)
                    threadRoot = nil
                    infoOpen = false
                    route = .home
                    if let first = matrix.rooms.first(where: {
                        !$0.isDirect && (id == nil || $0.spaceIDs.contains(id!))
                    }) {
                        selectRoom(first.id)
                    }
                }
            }
    }

    private var navigationObservedContent: some View {
        roomObservedContent
            .onChange(of: composerIdentity) { _, _ in
                logoutRecovery.invalidate()
                PlatformIntegration.shared.setNotificationAccount(matrix.isPreview ? nil : matrix.user?.id)
                resetUI()
                openPendingNotification()
            }
            .onChange(of: route) { _, next in
                if let request = pendingMatrixLink, request.route != next { cancelMatrixLink() }
                if next != .home {
                    cancelCurrentEdit()
                    cancelReply()
                    showPins = false
                    infoOpen = false
                    navigationGeneration = UUID()
                    pendingRoomID = nil
                    matrix.setMessageActionThread(rootID: nil)
                    threadRoot = nil
                    threadReadyID = nil
                    openingThreadID = nil
                }
            }
            .onChange(of: threadRoot?.eventID) { _, _ in updateActionThreadVisibility() }
            .onChange(of: threadReadyID) { _, _ in updateActionThreadVisibility() }
            .onChange(of: navigationGeneration) { _, _ in
                cancelStaleThreadOpen()
                cancelStaleForward()
                cancelStaleCaption()
            }
            .onChange(of: matrix.timelineSelectionID) { _, _ in cancelStaleThreadOpen() }
            .onChange(of: infoOpen) { _, _ in cancelStaleThreadOpen() }
            .onChange(of: matrix.messageActionContext) { _, _ in
                if let editActionTarget, !matrix.isCurrentMessageAction(editActionTarget) { cancelCurrentEdit() }
                cancelStaleForward()
                cancelStaleCaption()
            }
            .onChange(of: editContext) { _, _ in
                if let target = editTarget, !target.isCurrent(editTarget, in: editContext) { cancelCurrentEdit() }
                if let target = replyTarget, target.threadID != nil, !replyOpening,
                    target.threadID != threadRoot?.eventID
                {
                    cancelReply()
                }
            }
            .onChange(of: showPins) { _, shown in
                cancelStaleThreadOpen()
                if shown {
                    cancelCurrentEdit()
                    cancelReply()
                    cancelStaleForward()
                    cancelStaleCaption()
                }
            }
    }

    // A single long modifier chain exceeds the type checker's time limit in some Swift releases.
    private var observedContent: some View {
        navigationObservedContent
            .onChange(of: systemScheme) { _, scheme in appearance.systemIsDark = scheme == .dark }
            .onReceive(NotificationCenter.default.publisher(for: .menuAction)) { notification in
                handleMenu(notification.userInfo?["action"] as? String ?? "")
            }
            .onChange(of: appearance.notifications) { _, enabled in
                if !enabled { PlatformIntegration.shared.clearNotifications() }
            }
            .onChange(of: appearance.notificationPreview) { _, _ in platform.clearNotificationPreviews() }
    }

    private var linkPresentedContent: some View {
        mainContent
            .sheet(item: $matrixJoin) { selection in
                MatrixRoomJoinView(
                    matrix: matrix, request: selection.request,
                    onJoined: { finishMatrixJoin($0, selection: selection) }, onClose: { matrixJoin = nil }
                ).environmentObject(appearance)
            }
    }

    private var presentedContent: some View {
        linkPresentedContent
            .sheet(item: $publicDirectory) { selection in
                PublicRoomDirectoryView(
                    matrix: matrix, service: matrix.publicDirectory,
                    workspace: matrix.workspaces.first { $0.id == selection.workspaceID },
                    onResolve: { finishPublicDirectory($0, selection: selection) }, onClose: { publicDirectory = nil }
                ).environmentObject(appearance)
            }
            .sheet(item: $creation) { kind in
                CreationSheet(
                    matrix: matrix, kind: kind, workspaceID: workspaceID,
                    roomID: kind == .invite ? inviteTargetRoomID : matrix.selectedRoomID,
                    onCreated: { id, isWorkspace, notice in
                        if kind != .invite {
                            if isWorkspace {
                                workspaceID = id
                                workspaceInitialized = true
                            } else {
                                selectRoom(id)
                            }
                        }
                        navigationNotice = notice
                        creation = nil
                        inviteTargetRoomID = nil
                    },
                    onClose: {
                        creation = nil
                        inviteTargetRoomID = nil
                    }
                ).environmentObject(appearance)
            }
            .sheet(isPresented: $showRecovery) {
                EncryptionRecoveryView(matrix: matrix, onClose: { showRecovery = false }).environmentObject(appearance)
            }
            .sheet(item: $person) { selection in
                PersonProfileView(
                    matrix: matrix, people: matrix.people, userID: selection.id, fallback: selection.fallback,
                    onOpenConversation: { id in
                        person = nil
                        selectRoom(id)
                    }, onClose: { person = nil }
                ).environmentObject(appearance)
            }
            .sheet(item: $roomDetails) { selection in
                RoomDetailsEditor(matrix: matrix, roomID: selection.id, onClose: { roomDetails = nil })
                    .environmentObject(appearance)
            }
            .sheet(item: $roomNotifications) { selection in
                RoomNotificationSettingsView(matrix: matrix, roomID: selection.id, onClose: { roomNotifications = nil })
                    .environmentObject(appearance)
            }
            .sheet(item: $forwarding) { selection in
                ForwardMessageView(
                    matrix: matrix, target: selection.target,
                    onClose: {
                        guard forwarding?.id == selection.id else { return }
                        forwarding = nil
                    }
                ).environmentObject(appearance)
            }
            .sheet(item: $mediaCaption) { selection in
                MediaCaptionEditor(
                    matrix: matrix, target: selection.target,
                    onClose: {
                        guard mediaCaption?.id == selection.id else { return }
                        mediaCaption = nil
                    }
                ).environmentObject(appearance)
            }
            .modifier(VerificationPresentation(service: matrix.verification, enabled: !hasPresentedSheet))
            .sheet(item: Binding(get: { logoutRecovery.request }, set: { if $0 == nil { logoutRecovery.cancel() } })) {
                request in
                LogoutRecoveryView(
                    controller: logoutRecovery, request: request,
                    onRetry: { retryLogout(request) }, onLocalSignOut: { localLogout(request) },
                    onCancel: logoutRecovery.cancel)
            }
            .alert("Sign out of Slatrix?", isPresented: $logoutConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) { beginLogout() }.disabled(logoutRecovery.isBusy)
            } message: {
                Text("You’ll need your recovery key to read encrypted messages when you sign back in.")
            }
            .task {
                Task.detached(priority: .utility) { ComposerAttachmentImporter.cleanupOrphans() }
                matrix.notificationHandler = { notification in
                    let identity = composerIdentity
                    let session = matrix.notificationSessionID
                    guard appearance.notifications, identity.userID == notification.target.accountID,
                        !identity.isPreview
                    else { return }
                    platform.setNotificationAccount(identity.userID)
                    Task {
                        guard appearance.notifications, composerIdentity == identity,
                            matrix.notificationSessionID == session,
                            !(platform.conversationWindowIsVisible && route == .home && !showPins
                                && matrix.focusedEventID == nil && matrix.selectedRoomID == notification.target.roomID
                                && !hasModal && !hasNativeModal && !matrix.verification.isPresented)
                        else { return }
                        let value = notification.applyingPreviewPreference(appearance.notificationPreview)
                        do { try await platform.notify(value) } catch {
                            if composerIdentity == identity, matrix.notificationSessionID == session {
                                matrix.errorMessage = MatrixService.safeError(error)
                            }
                        }
                    }
                }
                await matrix.restore()
                bootstrapping = false
                loadLocalData()
                appearance.systemIsDark = systemScheme == .dark
                platform.setNotificationAccount(matrix.isPreview ? nil : matrix.user?.id)
                openPendingNotification()
            }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            titleBar
            if bootstrapping {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(colors.canvas)
                    .loadingInterval(.appLoading)
            } else if matrix.user == nil && !matrix.isPreview {
                LoginView(matrix: matrix) {
                    matrix.enterPreview()
                }.onAppear {
                    Performance.cancel(.launchRooms)
                    Performance.cancel(.launchConversation)
                }
            } else {
                IdentityGate(
                    verification: matrix.verification, accountID: matrix.isPreview ? nil : matrix.user?.id,
                    hasIdentity: { await matrix.accountHasIdentity() }, onRecovery: { showRecovery = true }
                ) {
                    HStack(spacing: 0) {
                        SidebarView(
                            matrix: matrix, route: $route,
                            workspaceID: Binding(
                                get: { workspaceID },
                                set: {
                                    Performance.start(.workspaceSwitch)
                                    workspaceID = $0
                                    workspaceInitialized = true
                                }), search: $sidebarSearch, draftRoomIDs: draftRoomIDs,
                            draftCount: draftAddresses.count,
                            onSelect: selectRoom, onCreate: presentCreation,
                            onPreferences: { handleMenu("preferences") },
                            onMarkUnread: { markReadState($0, unread: true) },
                            onMarkRead: { markReadState($0, unread: false) },
                            onInviteWorkspace: { id in
                                inviteTargetRoomID = id
                                creation = .invite
                            }, onEditWorkspace: { roomDetails = DetailsSelection(id: $0) },
                            onNotifications: { roomNotifications = DetailsSelection(id: $0) },
                            listWidth: sidebarListWidth,
                            listHidden: sidebarHidden, onBrowseChannels: presentPublicDirectory
                        ).layoutIsolated().frame(width: m.rail + (sidebarHidden ? 0 : sidebarListWidth))
                        if !sidebarHidden {
                            ResizeHandle(
                                currentWidth: sidebarListWidth, onChange: resizeSidebar, onCommit: commitSidebarWidth,
                                onReset: {
                                    resizingSidebarWidth = nil
                                    preferredSidebarWidth = Double(SidebarLayout.defaultWidth)
                                })
                        }
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                if route == .home {
                                    if let room {
                                        channelContent(room)
                                    } else if matrix.status == .connecting || matrix.status == .syncing {
                                        syncingView
                                    } else {
                                        noRoomsView
                                    }
                                } else {
                                    collectionContent
                                }
                            }
                            // A composer that grows or a message that arrives lays out this column, not the window.
                            .layoutIsolated()
                            // Transient states float over the conversation instead of pushing it down.
                            .overlay(alignment: .top) {
                                transientBanners.padding(.horizontal, m.sp16)
                                    .padding(
                                        .top,
                                        (route == .home && room != nil ? m.paneHeader + m.sp40 : m.paneHeader) + 1
                                            + m.sp8)
                            }
                            .overlay { if inspectorWidth == nil, let room { inspector(room) } }
                            if let width = inspectorWidth, let room {
                                ResizeHandle(
                                    pane: .trailing, label: threadRoot != nil ? "Thread width" : "Details width",
                                    currentWidth: m(width), onChange: resizePane, onCommit: commitPaneWidth,
                                    onReset: {
                                        resizingPaneWidth = nil
                                        preferredPaneWidth = 0
                                    })
                                inspector(room).layoutIsolated().frame(width: m(width))
                            }
                        }.background(colors.canvas).clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: m.radiusLarge,
                                topTrailingRadius: m.radiusLarge
                            ))
                    }.clipShape(RoundedRectangle(cornerRadius: m.radiusLarge)).overlay(
                        RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border)
                    ).padding(.trailing, m.sp4).padding(.bottom, m.sp4)
                }
            }
        }.background(colors.frame).foregroundStyle(colors.text).ignoresSafeArea(.container, edges: .top)
    }

    /// Connection, loading and error states, as toasts over the conversation.
    private var transientBanners: some View {
        VStack(spacing: m.sp8) {
            ConnectionBanner(matrix: matrix, onRetry: retryConnection)
            if pendingMatrixLink != nil {
                HStack(spacing: m.sp8) {
                    ProgressView().controlSize(.small)
                    Text("Opening…").font(m.font(.meta))
                    Spacer()
                    Button("Cancel") {
                        cancelMatrixLink()
                        openPendingNotification()
                    }.buttonStyle(.link)
                }.padding(m.sp12).modifier(Toast(colors: colors)).loadingInterval(.linkLoading)
            }
            if previews.isLoading {
                HStack(spacing: m.sp8) {
                    ProgressView().controlSize(.small)
                    Text("Opening preview…").font(m.font(.meta))
                    Spacer()
                    Button("Cancel") { previews.close() }.buttonStyle(.link)
                }.padding(m.sp12).modifier(Toast(colors: colors)).loadingInterval(.previewLoading)
            }
            if let request = pendingThreadOpen, isCurrentThreadOpen(request) {
                HStack(spacing: m.sp8) {
                    if let threadOpenError {
                        Text(threadOpenError).font(m.font(.meta)).foregroundStyle(colors.muted)
                        Button("Retry") {
                            if isCurrentThreadOpen(request) { openThread(request.message) }
                        }.buttonStyle(.link)
                    } else {
                        ProgressView().controlSize(.small).loadingInterval(.threadLoading)
                        Text("Opening thread…").font(m.font(.meta))
                    }
                    Spacer()
                    Button("Cancel") {
                        if pendingThreadOpen?.id == request.id { cancelThreadOpen() }
                    }.buttonStyle(.link)
                }.padding(m.sp12).modifier(Toast(colors: colors))
            }
            ErrorToast(matrix: matrix)
            if let navigationNotice {
                InlineErrorView(message: navigationNotice, dismiss: { self.navigationNotice = nil }).modifier(
                    Toast(colors: colors))
            }
            if let target = platform.pendingNotification, target.accountID == matrix.user?.id {
                HStack(spacing: m.sp8) {
                    ProgressView().controlSize(.small)
                    Text("Opening…").font(m.font(.meta))
                    Spacer()
                    Button("Cancel") { PlatformIntegration.shared.consumeNotification(target) }
                        .buttonStyle(.link).font(m.font(.meta))
                }.padding(m.sp12).modifier(Toast(colors: colors)).loadingInterval(.linkLoading)
            }
            if let localError {
                HStack {
                    InlineErrorView(message: localError)
                    Button("Retry") {
                        if localAccess == nil { loadLocalData(retry: true) } else { saveLocalData() }
                    }.buttonStyle(.link).padding(.trailing, m.sp16)
                }.modifier(Toast(colors: colors))
            }
            if let error = attachmentDrafts.errorMessage {
                HStack {
                    InlineErrorView(message: error)
                    Button("Retry saving") { retryAttachmentDrafts() }.buttonStyle(.link).padding(
                        .trailing, m.sp16)
                }.modifier(Toast(colors: colors))
            }
        }
        .font(m.font(.meta))
    }

    @ViewBuilder private func inspector(_ room: ChatRoom) -> some View {
        if let root = threadRoot {
            threadPanel(root: root, room: room)
        } else if infoOpen {
            RoomInfoView(
                matrix: matrix, room: room, onClose: { infoOpen = false },
                onInvite: { presentCreation(.invite) }, onRecovery: { showRecovery = true },
                onOpenProfile: openProfile,
                onEditDetails: { roomDetails = DetailsSelection(id: room.id) },
                onNotifications: { roomNotifications = DetailsSelection(id: room.id) }
            ).background(colors.canvas)
        }
    }

    private func resizeSidebar(_ width: CGFloat) {
        guard width.isFinite else { return }
        let limit = SidebarLayout.effective(
            preferred: SidebarLayout.maximumWidth, availableWidth: availableContentWidth / m.zoom,
            inspectorWidth: occupiedInspectorWidth)
        resizingSidebarWidth = min(limit, max(SidebarLayout.minimumWidth, width / m.zoom))
    }
    private func resizePane(_ width: CGFloat) {
        guard width.isFinite else { return }
        resizingPaneWidth = min(SidebarLayout.maximumPaneWidth, max(SidebarLayout.minimumPaneWidth, width / m.zoom))
    }
    private func commitPaneWidth() {
        guard resizingPaneWidth != nil else { return }
        // Keep what is on screen, not a drag past the limit, so a wider window later does not jump.
        if let shown = inspectorWidth { preferredPaneWidth = Double(shown) }
        resizingPaneWidth = nil
    }
    private func commitSidebarWidth() {
        guard let width = resizingSidebarWidth else { return }
        preferredSidebarWidth = Double(width)
        resizingSidebarWidth = nil
    }

    private func acknowledgeVisibleTimeline() async {
        guard let target = automaticReadTarget else { return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard platform.conversationWindowIsVisible, modals.current == nil,
                ReadStatePolicy.isCurrent(target, in: readContext, hold: readHold)
            else { return }
            try await matrix.markVisibleRead(target)
        } catch {
            // An unseen or offline snapshot stays unread; retry on the next visible live update.
        }
    }

    private var threadReadContext: ThreadReadContext { readInputs.threadReadContext(matrix) }
    private var automaticThreadReadTarget: ThreadReadReceiptTarget? { ThreadReadPolicy.target(threadReadContext) }
    private func acknowledgeVisibleThread() async {
        guard let target = automaticThreadReadTarget else { return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard platform.conversationWindowIsVisible, modals.current == nil,
                ThreadReadPolicy.isCurrent(target, in: threadReadContext)
            else {
                return
            }
            try await matrix.markVisibleThreadRead(target) {
                platform.conversationWindowIsVisible && ThreadReadPolicy.isCurrent(target, in: threadReadContext)
            }
        } catch {
            // Anything not confirmed as seen stays unread.
        }
    }

    private func retryConnection() {
        let account = matrix.notificationSessionID
        Task {
            guard matrix.notificationSessionID == account else { return }
            do { try await matrix.retryConnection() } catch is CancellationError {} catch {
                if matrix.notificationSessionID == account { matrix.errorMessage = MatrixService.safeError(error) }
            }
        }
    }

    private var readWindowChanges: Publishers.MergeMany<NotificationCenter.Publisher> {
        Publishers.MergeMany(
            [
                NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification, NSWindow.willCloseNotification,
            ].map { NotificationCenter.default.publisher(for: $0) })
    }
    private var readInputs: ReadInputs {
        ReadInputs(
            route: route, showPins: showPins, workspaceID: workspaceID, visibleBottomRoomID: visibleBottomRoomID,
            windowCanRead: windowCanRead, hasPresentedSheet: hasPresentedSheet, threadRootID: threadRoot?.eventID,
            threadReadyID: threadReadyID, openingThreadID: openingThreadID, threadLoadFailed: threadLoadError != nil,
            localReady: localReady, threadReadViewport: threadReadViewport, readHold: readHold)
    }
    private var readContext: ReadStateContext { readInputs.readContext(matrix) }
    private var automaticReadTarget: ReadReceiptTarget? { ReadStatePolicy.automaticTarget(readContext, hold: readHold) }
    private func markReadState(_ targetRoom: ChatRoom, unread: Bool) {
        guard !matrix.isPreview, targetRoom.membership == "join" else { return }
        if targetRoom.id == matrix.selectedRoomID {
            if unread { readHold.markUnread(readContext) } else { readHold.clearForExplicitRead(readContext) }
        }
        let account = matrix.notificationSessionID
        Task {
            guard matrix.notificationSessionID == account else { return }
            do { try await matrix.setMarkedUnread(targetRoom.id, value: unread) } catch {
                guard matrix.notificationSessionID == account else { return }
                matrix.errorMessage = MatrixService.safeError(error)
            }
        }
    }

    private var titleBar: some View {
        HStack(spacing: m.sp12) {
            // The window buttons are AppKit chrome and do not zoom.
            Color.clear.frame(width: Self.windowButtonsWidth)
            Spacer(minLength: 0)
            HStack(spacing: m.sp2) {
                IconButton(symbol: "arrow.left", label: "Back", role: .title) { navigateHistory(-1) }.disabled(
                    historyIndex <= 0)
                IconButton(symbol: "arrow.right", label: "Forward", role: .title) { navigateHistory(1) }.disabled(
                    historyIndex >= history.count - 1)
                HistoryMenu(matrix: matrix, history: history) { index in
                    historyIndex = index
                    selectRoom(history[index], record: false)
                }
            }
            Button {
                if matrix.user != nil { handleMenu("search") }
            } label: {
                HStack(spacing: m.sp8) {
                    Image(systemName: "magnifyingglass").font(m.font(.body))
                    Text("Search \(currentWorkspaceName)").font(m.font(.secondary))
                    Spacer()
                    Text("⌘ K").font(m.font(.caption)).opacity(0.65)
                }.padding(.horizontal, m.sp12).frame(height: m.row).background(
                    colors.primaryText.opacity(appearance.isDark ? 0.19 : 0.08),
                    in: RoundedRectangle(cornerRadius: m.radius))
            }.buttonStyle(.row).frame(maxWidth: m(Self.searchWidth)).disabled(matrix.user == nil)
            Spacer(minLength: 0)
            if matrix.isPreview {
                // The preview's one way out: everything else in it is the real interface.
                Button("Sign in") {
                    matrix.exitPreview()
                    resetUI()
                }.buttonStyle(.row).font(m.font(.secondary, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, m.sp12).frame(height: m.row)
                    .background(colors.accent, in: RoundedRectangle(cornerRadius: m.radius))
            }
            if updater.updateAvailable {
                Button("Update") { updater.checkForUpdates() }.buttonStyle(.row).font(m.font(.caption, .semibold))
                    .foregroundStyle(colors.canvas).padding(.horizontal, m.sp12).padding(.vertical, m.sp4)
                    .background(colors.accent, in: Capsule())
            }
            IconButton(symbol: "questionmark.circle", label: "Keyboard shortcuts", role: .title) {
                handleMenu("shortcuts")
            }
            .padding(.trailing, m.sp12)
        }.frame(height: m(Self.titleBarHeight)).background(WindowDragArea()).foregroundStyle(colors.text)
    }

    private func channelContent(_ room: ChatRoom) -> some View {
        VStack(spacing: 0) {
            channelHeader(room)
            Divider().overlay(colors.border)
            if room.membership == "invite" {
                inviteView(room)
            } else if showPins {
                PinnedMessagesView(
                    matrix: matrix, service: matrix.pinnedMessages, room: room,
                    onOpen: { message in selectRoom(message.roomID, record: true, eventID: message.eventID) },
                    onOpenProfile: openProfile)
            } else {
                if matrix.focusedEventID != nil {
                    HStack(spacing: m.sp8) {
                        Text("Viewing older messages")
                        Spacer()
                        Button("Jump to recent") { selectRoom(room.id) }.buttonStyle(.row).foregroundStyle(
                            colors.accent)
                    }.font(m.font(.meta)).padding(.horizontal, m.sp24).frame(height: m.control).background(
                        colors.raised)
                }
                TimelineView(
                    matrix: matrix, room: room, savedIDs: savedIDs,
                    onThread: openThreadAction,
                    onReply: { [session = matrix.notificationSessionID, timeline = matrix.timelineSelectionID] in
                        startReply($0, surface: .conversation, session: session, timeline: timeline)
                    }, onEdit: startEdit, onSave: toggleSave,
                    onShowReply: { selectRoom(room.id, record: true, eventID: $0) }, onOpenProfile: openProfile,
                    canPinMessages: canPin(room), onTogglePin: togglePin,
                    onBottomVisibilityChange: { visible in
                        if visible {
                            visibleBottomRoomID = room.id
                        } else if visibleBottomRoomID == room.id {
                            visibleBottomRoomID = nil
                        }
                    }, onJumpToLatest: { selectRoom(room.id) }, startsAtUnread: isResumingUnread,
                    onForward: startForward, onEditCaption: startCaption
                ).id("\(room.id):\(matrix.timelineSelectionID)")
                VStack(spacing: 0) {
                    if let target = editTarget, target.surface == .conversation, target.message.roomID == room.id {
                        editComposer(target, room: room).padding(.horizontal, m.sp20).padding(.vertical, m.sp4)
                    } else if matrix.focusedEventID != nil {
                        Button("Jump to recent") { selectRoom(room.id) }.buttonStyle(.link).font(m.font(.meta))
                            .padding(m.sp20)
                    } else {
                        BindingScope({ draftBinding(room.id) }) { text in
                            MessageComposer(
                                text: text,
                                placeholder: room.isDirect ? "Message \(room.name)" : "Message #\(room.name)",
                                members: matrix.members,
                                onSend: {
                                    [context = composerContext, reply = scopedReply(roomID: room.id)] body, files in
                                    try await send(body, files: files, room: room, context: context, reply: reply)
                                },
                                onTyping: { [context = composerContext] typing in
                                    guard isCurrentComposer(context), !context.identity.isPreview else { return }
                                    Task {
                                        guard isCurrentComposer(context) else { return }
                                        await matrix.setTyping(
                                            typing, roomID: room.id, sessionID: context.identity.sessionID)
                                    }
                                },
                                onSendText: { [context = composerContext, reply = scopedReply(roomID: room.id)] body in
                                    try await sendText(body, room: room, context: context, reply: reply)
                                },
                                onSendFile: { [context = composerContext] file in
                                    try await sendFile(file, room: room, context: context)
                                },
                                queuedFiles: attachmentBinding(AttachmentDraftAddress(roomID: room.id)),
                                sendingState: sendingBinding(room.id),
                                onError: { [context = composerContext] error in
                                    guard isCurrentComposer(context) else { return }
                                    matrix.errorMessage = error
                                },
                                allowsSend: attachmentDrafts.canSend(AttachmentDraftAddress(roomID: room.id))
                                    && replyAllowsSend(roomID: room.id),
                                onDiscardAttachments: attachmentDrafts.discard,
                                requiresTextForSend: scopedReply(roomID: room.id) != nil,
                                onConversationKey: { conversationKey($0, room: room, threadRootID: nil) },
                                isPrimary: true
                            )
                        }
                        .popover(item: $lastMessageReaction, arrowEdge: .top) { target in
                            ReactionPicker { key in
                                lastMessageReaction = nil
                                run { try await matrix.toggleReaction(target, key: key) }
                            }.padding(m.sp12)
                        }
                        .disabled(!localReady || !attachmentDrafts.ready).id(
                            "composer-\(composerGeneration)-\(room.id)"
                        )
                        .padding(.horizontal, m.sp20).padding(.top, m.sp4).padding(.bottom, m.sp4)
                    }
                }
                // Floats above the composer, so a reply or attachment notice never resizes it or moves the timeline.
                .overlay(alignment: .top) {
                    composerAccessories(
                        reply: replyTarget.flatMap {
                            $0.message.roomID == room.id && ($0.threadID == nil || $0.threadID != threadRoot?.eventID)
                                ? $0 : nil
                        },
                        drafts: editTarget == nil && matrix.focusedEventID == nil
                            ? AttachmentDraftAddress(roomID: room.id) : nil
                    ).padding(.horizontal, m.sp20).alignmentGuide(.top) { $0[.bottom] }
                }
                TypingLine(matrix: matrix)
            }
        }.task(id: room.id + (matrix.user?.id ?? "")) { await loadPinPermission(room) }
    }
    private func channelHeader(_ room: ChatRoom) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: m.sp8) {
                IconButton(
                    symbol: room.favorite ? "star.fill" : "star",
                    label: room.favorite ? "Remove from Starred" : "Add to Starred", role: .title
                ) { run { try await matrix.setFavorite(room, value: !room.favorite) } }
                Button {
                    matrix.setMessageActionThread(rootID: nil)
                    threadRoot = nil
                    infoOpen.toggle()
                    Task { await matrix.loadMembers() }
                } label: {
                    HStack(spacing: m.sp8) {
                        if !room.isDirect {
                            Image(systemName: room.isEncrypted ? "lock.fill" : "number").font(
                                m.font(.title, .bold))
                        }
                        Text(room.name).font(m.font(.title, .bold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(m.font(.caption, .semibold))
                    }
                }.buttonStyle(.row).foregroundStyle(colors.primaryText).layoutPriority(1)
                Spacer()
                Button {
                    matrix.setMessageActionThread(rootID: nil)
                    threadRoot = nil
                    infoOpen.toggle()
                    Task { await matrix.loadMembers() }
                } label: {
                    HStack(spacing: m.sp4) {
                        Image(systemName: "person")
                        Text("\(room.memberCount)").font(m.font(.meta))
                    }.padding(.horizontal, m.sp8).frame(height: m.iconButton)
                }.buttonStyle(.row).help("View members")
                IconButton(
                    symbol: room.muted ? "bell.slash" : "bell", label: "Conversation notifications", role: .title
                ) {
                    roomNotifications = DetailsSelection(id: room.id)
                }.disabled(matrix.isPreview || room.membership != "join")
                IconButton(symbol: "magnifyingglass", label: "Search in conversation", role: .title) {
                    handleMenu("search-conversation")
                }
                Menu {
                    Button("Channel details") {
                        infoOpen = true
                        matrix.setMessageActionThread(rootID: nil)
                        threadRoot = nil
                    }
                    Button("Invite people…") { presentCreation(.invite) }.disabled(
                        matrix.isPreview || room.membership != "join" || room.canInvite == false)
                    Divider()
                    Button("Mark unread") { markReadState(room, unread: true) }.disabled(
                        matrix.isPreview || room.membership != "join")
                    Button("Mark read") { markReadState(room, unread: false) }.disabled(
                        matrix.isPreview || room.membership != "join")
                    Divider()
                    Button("Copy link") {
                        run {
                            let link = try await matrix.roomPermalink(room.id)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                        }
                    }.disabled(matrix.isPreview)
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(
                        width: m.iconButton, height: m.iconButton)
                }.menuStyle(.borderlessButton).frame(width: m.iconButton)
            }.padding(.horizontal, m.sp20).frame(height: m.paneHeader)
            HStack(spacing: m.sp24) {
                Button {
                    showPins = false
                    route = .home
                } label: {
                    Label("Messages", systemImage: "bubble.left.fill").font(
                        m.font(.secondary, showPins ? .regular : .semibold)
                    ).fixedSize().padding(.vertical, m.sp12).overlay(alignment: .bottom) {
                        if !showPins { Rectangle().fill(colors.text).frame(height: 2) }
                    }
                }.buttonStyle(.row)
                Button {
                    matrix.setMessageActionThread(rootID: nil)
                    threadRoot = nil
                    infoOpen = false
                    showPins = true
                } label: {
                    Label(
                        room.pinnedEventIDs.isEmpty ? "Pins" : "Pins · \(room.pinnedEventIDs.count)", systemImage: "pin"
                    ).font(m.font(.secondary, showPins ? .semibold : .regular)).fixedSize().padding(.vertical, m.sp12)
                        .overlay(
                            alignment: .bottom
                        ) { if showPins { Rectangle().fill(colors.text).frame(height: 2) } }
                }.buttonStyle(.row).disabled(matrix.isPreview || room.membership != "join")
                Button {
                    route = .files
                } label: {
                    Label("Files & links", systemImage: "doc.on.doc").font(m.font(.secondary)).fixedSize()
                }.buttonStyle(.row).foregroundStyle(colors.muted)
                Spacer()
                // In the tab row's reserved height, so it never covers or moves a message.
                if matrix.hasLockedMessages {
                    Button {
                        showRecovery = true
                    } label: {
                        Label("Unlock messages", systemImage: "key").font(m.font(.meta, .medium))
                    }.buttonStyle(.row).foregroundStyle(colors.accent).disabled(matrix.isPreview)
                } else if room.isEncrypted {
                    Image(systemName: "lock.shield").font(m.font(.meta)).foregroundStyle(colors.muted).help(
                        "End-to-end encrypted")
                }
            }.padding(.horizontal, m.sp24).frame(height: m.sp40)
        }
    }
    private func threadPanel(root: ChatMessage, room: ChatRoom) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: m.sp8) {
                Text("Thread").font(m.font(.title, .bold))
                Text(room.name).font(m.font(.caption)).foregroundStyle(colors.muted).lineLimit(1)
                Spacer()
                IconButton(symbol: "xmark", label: "Close thread", role: .body, action: closeThread)
            }.padding(.horizontal, m.sp20).frame(height: m.paneHeader)
            Divider().overlay(colors.border)
            if let threadLoadError {
                HStack {
                    InlineErrorView(message: threadLoadError)
                    Button("Retry") { [open = openThreadAction] in open(root) }.buttonStyle(.link).font(
                        m.font(.meta)
                    ).padding(.trailing, m.sp12)
                }
            }
            TimelineView(
                matrix: matrix, room: room, thread: true, threadRootID: root.eventID,
                savedIDs: savedIDs, onThread: { _ in },
                onReply: { [session = matrix.notificationSessionID, timeline = matrix.timelineSelectionID] in
                    startReply($0, surface: .thread(rootID: root.eventID), session: session, timeline: timeline)
                }, onEdit: startEdit, onSave: toggleSave,
                onShowReply: { selectRoom(room.id, record: true, eventID: $0) }, onOpenProfile: openProfile,
                canPinMessages: canPin(room), onTogglePin: togglePin,
                onBottomVisibilityChange: { [identity = matrix.threadReadIdentity] visible in
                    threadReadViewport.record(visible, from: identity, current: matrix.threadReadIdentity)
                }, onForward: startForward, onEditCaption: startCaption
            ).id(root.eventID)
                .overlay { ThreadProgress(matrix: matrix, active: openingThreadID == root.eventID) }
            VStack(spacing: 0) {
                if let target = editTarget, target.surface == .thread(rootID: root.eventID),
                    target.message.roomID == room.id
                {
                    editComposer(target, room: room).padding(m.sp12)
                } else {
                    BindingScope({ threadDraftBinding(root.eventID, roomID: room.id) }) { text in
                        MessageComposer(
                            text: text, placeholder: "Reply…",
                            members: matrix.members,
                            onSend: {
                                [
                                    context = composerContext,
                                    reply = scopedReply(roomID: room.id, threadID: root.eventID)
                                ]
                                body, files
                                in
                                try await send(
                                    body, files: files, room: room, threadID: root.eventID, context: context,
                                    reply: reply)
                            },
                            onTyping: { _ in },
                            onSendText: {
                                [
                                    context = composerContext,
                                    reply = scopedReply(roomID: room.id, threadID: root.eventID)
                                ]
                                body
                                in
                                try await sendText(
                                    body, room: room, threadID: root.eventID, context: context, reply: reply)
                            },
                            onSendFile: { [context = composerContext] file in
                                try await sendFile(file, room: room, threadID: root.eventID, context: context)
                            },
                            queuedFiles: attachmentBinding(
                                AttachmentDraftAddress(roomID: room.id, threadRootID: root.eventID)),
                            sendingState: sendingBinding("thread:" + root.eventID),
                            onError: { [context = composerContext] error in
                                guard isCurrentComposer(context) else { return }
                                matrix.errorMessage = error
                            },
                            allowsSend: attachmentDrafts.canSend(
                                AttachmentDraftAddress(roomID: room.id, threadRootID: root.eventID))
                                && replyAllowsSend(roomID: room.id, threadID: root.eventID),
                            onDiscardAttachments: attachmentDrafts.discard,
                            requiresTextForSend: scopedReply(roomID: room.id, threadID: root.eventID) != nil,
                            onConversationKey: { conversationKey($0, room: room, threadRootID: root.eventID) }
                        )
                    }
                    .id("thread-composer-\(composerGeneration)-\(root.eventID)").padding(m.sp12).disabled(
                        !localReady || !attachmentDrafts.ready || matrix.focusedEventID != nil
                            || threadReadyID != root.eventID
                            || matrix.selectedRoomID != root.roomID)
                }
            }
            .overlay(alignment: .top) {
                composerAccessories(
                    reply: replyTarget.flatMap { $0.belongsTo(roomID: room.id, threadID: root.eventID) ? $0 : nil },
                    drafts: editTarget == nil
                        ? AttachmentDraftAddress(roomID: room.id, threadRootID: root.eventID) : nil
                ).padding(.horizontal, m.sp12).alignmentGuide(.top) { $0[.bottom] }
            }
        }.background(colors.canvas)
    }
    private var collectionContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text(route.title).font(m.font(.title, .bold))
                Spacer()
                if route == .directMessages || route == .directory {
                    ActionButton(title: "New message", symbol: "square.and.pencil") { creation = .directMessage }
                }
            }.padding(.horizontal, m.sp24).frame(height: m.paneHeader)
            Divider().overlay(colors.border)
            switch route {
            case .directMessages: RoomDirectory(matrix: matrix, onSelect: selectRoom)
            case .directory: PeopleDirectoryView(matrix: matrix, people: matrix.people, onOpenProfile: openProfile)
            case .threads:
                ThreadsFeedView(
                    matrix: matrix, feed: matrix.threadFeed, workspaceID: $workspaceID, onOpen: openThreadAction)
            case .files:
                SharedFilesView(
                    matrix: matrix, service: matrix.sharedFiles, workspaceID: workspaceID,
                    onOpen: { selectRoom($0.roomID, record: true, eventID: $0.eventID) }, onOpenProfile: openProfile)
            case .saved: savedCollection
            case .drafts: draftsCollection
            case .activity:
                ActivityFeedView(
                    matrix: matrix, activity: matrix.activity, workspaceID: $workspaceID, onOpenMessage: openActivity,
                    onOpenRoom: selectRoom)
            case .home: EmptyView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var savedCollection: some View {
        SavedMessagesView(
            matrix: matrix, saved: saved,
            onOpen: { item in selectRoom(item.roomID, record: true, eventID: item.eventID) },
            onRemove: { item in
                saved.removeAll { $0.id == item.id }
                saveLocalData()
            }, onOpenProfile: openProfile
        ).id(composerGeneration)
    }
    private var draftsCollection: some View {
        let pending = draftAddresses.sorted { $0.id < $1.id }
        return Group {
            if pending.isEmpty {
                EmptyStateView(symbol: "paperplane", title: "No drafts")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pending, id: \.self) { address in
                            Button {
                                if let root = address.threadRootID {
                                    openThreadDraft(ThreadDraftAddress(roomID: address.roomID, rootID: root))
                                } else {
                                    selectRoom(address.roomID)
                                }
                            } label: {
                                draftRow(
                                    roomID: address.roomID, body: draftSummary(address),
                                    thread: address.threadRootID != nil)
                            }.buttonStyle(.row)
                            Divider().overlay(colors.border).padding(.leading, m.sp24)
                        }
                    }
                }
            }
        }
    }
    private func draftSummary(_ address: AttachmentDraftAddress) -> String {
        let text =
            address.threadRootID.map {
                drafts.threads[ThreadDraftAddress(roomID: address.roomID, rootID: $0).id] ?? ""
            } ?? drafts.conversations[address.roomID] ?? ""
        let count = max(attachmentDrafts.queues[address]?.count ?? 0, attachmentDrafts.files[address]?.count ?? 0)
        return text + (count == 0 ? "" : (text.isEmpty ? "" : "\n") + "\(count) attachment\(count == 1 ? "" : "s")")
    }
    @ViewBuilder private func attachmentDraftStatus(_ address: AttachmentDraftAddress) -> some View {
        if !attachmentDrafts.ready {
            HStack(spacing: m.sp8) {
                ProgressView().controlSize(.small)
                Text("Restoring attachments…")
                Spacer()
            }.font(m.font(.meta)).foregroundStyle(colors.muted).padding(m.sp12).modifier(Toast(colors: colors))
                .loadingInterval(.attachmentsLoading)
        }
        if localReady && attachmentDrafts.needsReview(address) {
            HStack(alignment: .top, spacing: m.sp8) {
                Image(systemName: "exclamationmark.triangle")
                Text("Upload interrupted; it may have sent.")
                Spacer()
                Button("Send anyway") { attachmentDrafts.allowResend(address) }.buttonStyle(.link)
            }.font(m.font(.meta)).padding(m.sp12).modifier(Toast(colors: colors))
        }
        ForEach(localReady ? attachmentDrafts.files[address, default: []].filter { $0.url == nil } : []) { file in
            HStack(alignment: .top, spacing: m.sp8) {
                Image(systemName: "doc.badge.exclamationmark")
                VStack(alignment: .leading, spacing: m.sp4) {
                    Text(file.filename).fontWeight(.medium)
                    Text(file.errorMessage ?? "Saved attachment unavailable")
                }
                Spacer()
                Button("Remove") { attachmentDrafts.removeUnavailable(file, at: address) }.buttonStyle(.link)
            }.font(m.font(.meta)).padding(m.sp12).modifier(Toast(colors: colors))
        }
    }
    private func retryAttachmentDrafts() {
        let identity = composerIdentity
        Task {
            guard composerIdentity == identity else { return }
            if !attachmentDrafts.ready {
                await attachmentDrafts.open(accountID: matrix.isPreview ? nil : identity.userID)
            } else {
                do { try await attachmentDrafts.flush() } catch { matrix.errorMessage = error.localizedDescription }
            }
        }
    }
    private func draftRow(roomID: String, body: String, thread: Bool) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            HStack(spacing: m.sp8) {
                Image(systemName: thread ? "bubble.left.and.bubble.right" : "square.and.pencil").foregroundStyle(
                    colors.muted)
                RoomName(matrix: matrix, roomID: roomID).font(m.font(.body, .semibold))
                if thread { Text("Thread reply").font(m.font(.caption)).foregroundStyle(colors.muted) }
                Spacer()
                Image(systemName: "chevron.right").font(m.font(.caption)).foregroundStyle(colors.muted)
            }
            Text(body).font(m.font(.secondary)).foregroundStyle(colors.muted).lineLimit(3)
        }.padding(m.sp24).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func openThreadDraft(_ address: ThreadDraftAddress) {
        let identity = composerIdentity
        let request = UUID()
        navigationGeneration = request
        Task {
            do {
                let root = try await matrix.messagePreview(roomID: address.roomID, eventID: address.rootID)
                guard composerIdentity == identity, navigationGeneration == request else { return }
                openThread(root)
            } catch {
                guard composerIdentity == identity, navigationGeneration == request else { return }
                matrix.errorMessage = MatrixService.safeError(error)
            }
        }
    }
    private var syncingView: some View {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).loadingInterval(.conversationLoading)
    }
    private var noRoomsView: some View {
        let workspace = matrix.workspaces.first { $0.id == workspaceID }
        return EmptyStateView(
            symbol: workspace == nil ? "bubble.left.and.bubble.right" : "number",
            title: workspace == nil ? "No conversations yet" : "No channels yet"
        ) {
            if let workspace {
                Button("Create a channel") { presentCreation(.channel) }
                    .disabled(matrix.isPreview || workspace.canManageRooms == false)
            } else {
                Button("Join a conversation") { presentCreation(.join) }
            }
        }
    }
    private func inviteView(_ room: ChatRoom) -> some View {
        let busy = matrix.pendingInvitationRoomIDs.contains(room.id)
        return VStack(spacing: m.sp20) {
            EmptyStateView(
                symbol: room.isSpace ? "square.stack.3d.up" : "envelope.open", title: "You’re invited to \(room.name)"
            ).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: m.sp12) {
                ActionButton(title: "Decline") { respondToInvitation(room, accepting: false) }
                ActionButton(title: room.isSpace ? "Join workspace" : "Join", prominent: true) {
                    respondToInvitation(room, accepting: true)
                }
            }.disabled(busy || matrix.isPreview)
            // Reserved, so the buttons never move when the spinner comes and goes.
            ProgressView().controlSize(.small).opacity(busy ? 1 : 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func respondToInvitation(_ room: ChatRoom, accepting: Bool) {
        let session = matrix.notificationSessionID
        let navigation = navigationGeneration
        invitationResponseID = room.id
        Task {
            defer {
                if invitationResponseID == room.id {
                    invitationResponseID = nil
                    if matrix.notificationSessionID == session, navigationGeneration == navigation,
                        matrix.selectedRoomID == room.id, !matrix.rooms.contains(where: { $0.id == room.id }),
                        let first = matrix.rooms.first(where: {
                            $0.membership == "join" && !$0.isDirect
                                && (workspaceID == nil || $0.spaceIDs.contains(workspaceID!))
                        })
                    {
                        selectRoom(first.id)
                    }
                }
            }
            guard matrix.notificationSessionID == session else { return }
            do {
                if accepting {
                    let destination = try await matrix.acceptInvitation(room.id)
                    guard matrix.notificationSessionID == session, navigationGeneration == navigation,
                        matrix.selectedRoomID == room.id
                    else { return }
                    if destination.kind == .workspace {
                        workspaceID = destination.id
                        workspaceInitialized = true
                        preferredRoomID = nil
                    } else {
                        selectRoom(destination.id)
                    }
                } else {
                    try await matrix.declineInvitation(room.id)
                }
            } catch is CancellationError {} catch {
                if matrix.notificationSessionID == session, navigationGeneration == navigation,
                    matrix.selectedRoomID == room.id
                {
                    matrix.errorMessage = MatrixService.safeError(error)
                }
            }
        }
    }
    private func presentCreation(_ kind: CreationKind) {
        inviteTargetRoomID = kind == .invite ? matrix.selectedRoomID : nil
        creation = kind
    }
    private var replyOwner: MessageReplyTarget.Owner {
        .init(userID: matrix.user?.id, sessionID: matrix.notificationSessionID)
    }
    private func scopedReply(roomID: String, threadID: String? = nil) -> MessageReplyTarget? {
        replyTarget.flatMap { $0.belongsTo(roomID: roomID, threadID: threadID) ? $0 : nil }
    }
    private func replyAllowsSend(roomID: String, threadID: String? = nil) -> Bool {
        if threadID == nil, let target = replyTarget, target.message.roomID == roomID,
            target.threadID != nil, target.threadID != threadRoot?.eventID
        {
            return false
        }
        return scopedReply(roomID: roomID, threadID: threadID) == nil || (!replyOpening && replyError == nil)
    }
    private func cancelReply() {
        replyTarget = nil
        replyOpening = false
        replyError = nil
    }
    private func replyBanner(_ target: MessageReplyTarget) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            HStack(alignment: .top, spacing: m.sp12) {
                Rectangle().fill(colors.accent).frame(width: 3, height: m.control)
                VStack(alignment: .leading, spacing: m.sp4) {
                    Text("Replying to \(target.message.senderName)\(target.threadID == nil ? "" : " in thread")").font(
                        m.font(.caption, .semibold))
                    NativeMessageBody(
                        body: target.message.body, formattedBody: target.message.formattedBody,
                        showsSpoilerControl: false
                    ).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Cancel reply", role: .meta) {
                    guard target.isCurrent(replyTarget, owner: replyOwner) else { return }
                    cancelReply()
                }
            }.overlay(alignment: .trailing) {
                DelayedProgress(active: replyOpening, interval: .replyLoading).padding(.trailing, m.iconButton + m.sp8)
            }
            if !replyOpening, let replyError {
                HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                    Text(replyError).foregroundStyle(colors.muted)
                    Button("Retry") { prepareReply(target) }.buttonStyle(.link)
                }.font(m.font(.meta))
            }
        }.padding(.horizontal, m.sp16).padding(.vertical, m.sp8).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Toast(colors: colors))
    }
    private func composerAccessories(reply: MessageReplyTarget?, drafts: AttachmentDraftAddress?) -> some View {
        VStack(alignment: .leading, spacing: m.sp4) {
            if let reply { replyBanner(reply) }
            if let drafts { attachmentDraftStatus(drafts) }
        }.padding(.bottom, m.sp4)
    }
    private func startReply(_ message: ChatMessage, surface: MessageReplyTarget.Surface, session: UUID, timeline: UUID)
    {
        guard !matrix.isPreview, localReady, pendingRoomID == nil, route == .home, !showPins,
            room?.id == message.roomID, room?.membership == "join",
            matrix.notificationSessionID == session, matrix.timelineSelectionID == timeline
        else { return }
        if case .thread(let rootID) = surface {
            guard threadRoot?.eventID == rootID, threadReadyID == rootID else { return }
        }
        guard let target = MessageReplyTarget(message: message, surface: surface, owner: replyOwner) else { return }
        cancelCurrentEdit()
        replyTarget = target
        prepareReply(target)
    }
    private func prepareReply(_ target: MessageReplyTarget) {
        guard target.isCurrent(replyTarget, owner: replyOwner), !matrix.isPreview,
            route == .home, !showPins, room?.id == target.message.roomID, room?.membership == "join"
        else { return }
        replyError = nil
        if pendingRoomID == nil, matrix.isLiveTimelineReady(roomID: target.message.roomID),
            target.threadID == nil || (threadRoot?.eventID == target.threadID && threadReadyID == target.threadID)
        {
            replyOpening = false
            return
        }
        let generation = UUID()
        navigationGeneration = generation
        replyOpening = true
        Task { @MainActor in
            @MainActor func isCurrent() -> Bool {
                navigationGeneration == generation && target.isCurrent(replyTarget, owner: replyOwner) && route == .home
                    && !showPins && room?.id == target.message.roomID && room?.membership == "join"
            }
            guard isCurrent() else { return }
            do {
                var root: ChatMessage?
                if let rootID = target.threadID {
                    root = try await ThreadRootResolver.resolve(
                        roomID: target.message.roomID, rootID: rootID,
                        candidates: matrix.messages + matrix.threadMessages + matrix.threadFeed.items.map(\.root),
                        load: { try await matrix.messagePreview(roomID: $0, eventID: $1) },
                        validate: { guard isCurrent() else { throw CancellationError() } })
                    guard isCurrent() else { return }
                    guard let root, root.eventID == rootID, root.roomID == target.message.roomID, !root.isRedacted,
                        root.threadRootID == nil
                    else {
                        throw MatrixServiceError.request("The thread’s first message is gone. Your draft is kept.")
                    }
                }
                guard isCurrent() else { return }
                selectRoom(target.message.roomID, record: true, thread: root, restoringReply: target)
            } catch {
                guard isCurrent() else { return }
                replyOpening = false
                replyError = MatrixService.safeError(error)
            }
        }
    }

    private func selectRoom(_ id: String) { selectRoom(id, record: true) }
    private func selectRoom(
        _ id: String, record: Bool, eventID: String? = nil, thread: ChatMessage? = nil,
        keepPendingNotification: Bool = false, restoringReply: MessageReplyTarget? = nil
    ) {
        cancelThreadOpen()
        if !keepPendingNotification, let target = PlatformIntegration.shared.pendingNotification {
            PlatformIntegration.shared.consumeNotification(target)
        }
        navigationNotice = nil
        let resumeAnchor =
            matrix.isPreview || restoringReply != nil
            ? nil
            : UnreadNavigation.resumeAnchor(
                for: matrix.rooms.first { $0.id == id }, selectedRoomID: matrix.selectedRoomID,
                explicitEventID: eventID, opensThread: thread != nil)
        let destinationEventID = eventID ?? resumeAnchor
        let requiresRoomSelection = !matrix.isLiveTimelineReady(roomID: id) || pendingRoomID != nil
        // The cases below that open a new timeline.
        if destinationEventID != nil || thread == nil || requiresRoomSelection {
            Performance.start(.roomOpen)
            if !matrix.isPreview { Performance.start(.roomTimeline) }
        }
        let generation = UUID()
        let identity = composerIdentity
        navigationGeneration = generation
        if record && history.last != id {
            if historyIndex + 1 < history.count { history = Array(history.prefix(historyIndex + 1)) }
            history.append(id)
            historyIndex = history.count - 1
        }
        pendingRoomID = id
        if let target = matrix.rooms.first(where: { $0.id == id }) {
            if !target.isDirect, let current = workspaceID, !target.spaceIDs.contains(current) {
                workspaceID = WorkspaceRail.home(of: target, current: current, workspaces: matrix.workspaces)
                workspaceInitialized = true
            }
        } else {
            workspaceID = nil
            workspaceInitialized = true
        }
        route = .home
        showPins = false
        matrix.setMessageActionThread(rootID: nil)
        threadRoot = nil
        threadReadyID = nil
        openingThreadID = nil
        threadLoadError = nil
        cancelCurrentEdit()
        if restoringReply == nil { cancelReply() }
        unreadResumeEventID = resumeAnchor
        preferredRoomID = id
        UserDefaults.standard.set(id, forKey: "room.\(storageKey)")
        if matrix.isPreview {
            matrix.selectPreviewRoom(id)
            pendingRoomID = nil
            if let thread {
                threadRoot = thread
                matrix.openPreviewThread(thread)
                threadReadyID = thread.eventID
            }
        } else {
            // A conversation still open from earlier goes up with this click; the task below then finds it shown.
            if restoringReply == nil, eventID == nil { _ = matrix.showRecentRoom(id, containing: resumeAnchor) }
            Task { @MainActor in
                guard navigationGeneration == generation, composerIdentity == identity else { return }
                if let restoringReply {
                    guard restoringReply.isCurrent(replyTarget, owner: replyOwner), route == .home, !showPins,
                        room?.id == id
                    else {
                        pendingRoomID = nil
                        return
                    }
                }
                if let resumeAnchor, eventID == nil {
                    await matrix.resumeRoom(id, at: resumeAnchor)
                } else if let destinationEventID {
                    await matrix.jumpToMessage(roomID: id, eventID: destinationEventID)
                } else if thread == nil || requiresRoomSelection {
                    await matrix.selectRoom(id)
                }
                guard navigationGeneration == generation, composerIdentity == identity, matrix.selectedRoomID == id
                else { return }
                pendingRoomID = nil
                if let restoringReply {
                    guard restoringReply.isCurrent(replyTarget, owner: replyOwner), route == .home, !showPins,
                        room?.id == id
                    else { return }
                    guard matrix.isLiveTimelineReady(roomID: id) else {
                        replyOpening = false
                        replyError = "Couldn’t load recent messages. Try again."
                        return
                    }
                }
                if let thread {
                    threadRoot = thread
                    infoOpen = false
                    openingThreadID = thread.eventID
                    do {
                        try await matrix.loadThread(thread)
                        guard navigationGeneration == generation, composerIdentity == identity,
                            matrix.selectedRoomID == id, threadRoot?.eventID == thread.eventID
                        else { return }
                        threadReadyID = thread.eventID
                        openingThreadID = nil
                        Performance.finishOnScreen(.threadOpen, ["messages": matrix.threadMessages.count])
                        if let restoringReply, restoringReply.isCurrent(replyTarget, owner: replyOwner) {
                            replyOpening = false
                            replyError = nil
                        }
                    } catch {
                        guard navigationGeneration == generation, composerIdentity == identity,
                            matrix.selectedRoomID == id
                        else { return }
                        openingThreadID = nil
                        if let restoringReply, restoringReply.isCurrent(replyTarget, owner: replyOwner) {
                            replyOpening = false
                            replyError = MatrixService.safeError(error)
                        } else {
                            threadLoadError = MatrixService.safeError(error)
                        }
                    }
                } else if let restoringReply, restoringReply.isCurrent(replyTarget, owner: replyOwner) {
                    replyOpening = false
                    replyError = nil
                }
            }
        }
    }
    private func navigateHistory(_ step: Int) {
        let next = historyIndex + step
        guard history.indices.contains(next) else { return }
        historyIndex = next
        selectRoom(history[next], record: false)
    }
    private var openThreadAction: (ChatMessage) -> Void {
        let owner = composerIdentity
        let selection = matrix.timelineSelectionID
        let navigation = navigationGeneration
        let workspace = workspaceID
        let sourceRoute = route
        return { message in
            guard owner == composerIdentity, selection == matrix.timelineSelectionID,
                navigation == navigationGeneration,
                workspace == workspaceID, sourceRoute == route
            else { return }
            openThread(message)
        }
    }
    private func openThread(_ message: ChatMessage) {
        guard pendingRoomID == nil, localReady,
            matrix.rooms.contains(where: { $0.id == message.roomID && $0.membership == "join" })
        else { return }
        let rootID = message.threadRootID ?? message.eventID
        let candidates = [message] + matrix.messages + matrix.threadMessages + matrix.threadFeed.items.map(\.root)
        if matrix.isPreview {
            guard let root = candidates.first(where: { $0.eventID == rootID && $0.roomID == message.roomID }) else {
                return
            }
            selectRoom(root.roomID, record: true, thread: root)
            return
        }
        Performance.start(.threadOpen)
        cancelThreadOpen()
        cancelReply()
        navigationGeneration = UUID()
        let request = ThreadOpenRequest(
            message: message, owner: composerIdentity,
            selection: matrix.timelineSelectionID, navigation: navigationGeneration,
            workspace: workspaceID, informationVisible: infoOpen, sourceRoute: route,
            selectedRoomID: matrix.selectedRoomID, pinsVisible: showPins)
        pendingThreadOpen = request
        threadOpenTask = Task { @MainActor in
            do {
                let root = try await ThreadRootResolver.resolve(
                    roomID: message.roomID, rootID: rootID, candidates: candidates,
                    load: { try await matrix.messagePreview(roomID: $0, eventID: $1) },
                    validate: { guard isCurrentThreadOpen(request) else { throw CancellationError() } })
                guard isCurrentThreadOpen(request) else { return }
                threadOpenTask = nil
                pendingThreadOpen = nil
                threadOpenError = nil
                selectRoom(root.roomID, record: true, thread: root)
            } catch is CancellationError {
                if pendingThreadOpen?.id == request.id { cancelThreadOpen() }
            } catch {
                guard isCurrentThreadOpen(request) else {
                    if pendingThreadOpen?.id == request.id { cancelThreadOpen() }
                    return
                }
                threadOpenTask = nil
                threadOpenError =
                    (error as? ThreadRootResolver.Failure)?.localizedDescription ?? MatrixService.safeError(error)
            }
        }
    }
    private func isCurrentThreadOpen(_ request: ThreadOpenRequest) -> Bool {
        pendingThreadOpen?.id == request.id && request.owner == composerIdentity && !matrix.isPreview
            && request.selection == matrix.timelineSelectionID && request.navigation == navigationGeneration
            && request.workspace == workspaceID && request.informationVisible == infoOpen
            && route == request.sourceRoute && showPins == request.pinsVisible && pendingRoomID == nil && localReady
            && matrix.selectedRoomID == request.selectedRoomID
            && matrix.rooms.contains(where: { $0.id == request.message.roomID && $0.membership == "join" })
    }
    private func cancelThreadOpen() {
        threadOpenTask?.cancel()
        threadOpenTask = nil
        pendingThreadOpen = nil
        threadOpenError = nil
    }
    private func cancelStaleThreadOpen() {
        if let request = pendingThreadOpen, !isCurrentThreadOpen(request) { cancelThreadOpen() }
    }
    private func openPendingNotification() {
        let platform = PlatformIntegration.shared
        if resumeMatrixLink() { return }
        guard !bootstrapping, !hasModal, !hasNativeModal, !matrix.verification.isPresented,
            let target = platform.pendingNotification,
            !matrix.isPreview, matrix.user?.id == target.accountID,
            let destination = matrix.rooms.first(where: { $0.id == target.roomID })
        else { return }
        platform.consumeNotification(target)
        selectRoom(target.roomID, record: true, eventID: destination.membership == "join" ? target.eventID : nil)
    }
    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        if MatrixLinkService.isMatrixCandidate(url) {
            enqueueMatrixLink(url)
            return .handled
        }
        do {
            try platform.openExternal(url)
            return .handled
        } catch {
            matrix.errorMessage = error.localizedDescription
            return .discarded
        }
    }
    private func presentPublicDirectory() {
        guard !hasModal, !hasNativeModal, !matrix.verification.isPresented,
            let accountID = matrix.user?.id, !matrix.isPreview
        else { return }
        cancelMatrixLink()
        publicDirectory = PublicDirectorySelection(
            accountID: accountID, session: matrix.notificationSessionID, navigation: navigationGeneration, route: route,
            workspaceID: workspaceID)
    }
    private func finishPublicDirectory(_ resolution: MatrixLinkResolution, selection: PublicDirectorySelection) {
        guard publicDirectory?.id == selection.id else { return }
        guard matrix.user?.id == selection.accountID, matrix.notificationSessionID == selection.session,
            resolution.accountID == selection.accountID, resolution.sessionID == selection.session, !matrix.isPreview
        else {
            publicDirectory = nil
            return
        }
        guard navigationGeneration == selection.navigation, route == selection.route,
            workspaceID == selection.workspaceID
        else {
            publicDirectory = nil
            navigationNotice = "You moved on. Open Browse channels to try again."
            return
        }
        cancelMatrixLink()
        pendingMatrixLink = PendingMatrixLink(
            source: .resolved(resolution), accountID: selection.accountID, session: selection.session,
            navigation: selection.navigation, route: selection.route, workspaceID: selection.workspaceID)
        publicDirectory = nil
        _ = resumeMatrixLink()
    }
    private func enqueueMatrixLink(_ url: URL) {
        guard let accountID = matrix.user?.id, !matrix.isPreview else {
            matrix.errorMessage = "Sign in to open this link."
            return
        }
        cancelMatrixLink()
        pendingMatrixLink = PendingMatrixLink(
            source: .url(url), accountID: accountID, session: matrix.notificationSessionID,
            navigation: navigationGeneration, route: route, workspaceID: workspaceID)
        _ = resumeMatrixLink()
    }
    private func cancelMatrixLink() {
        matrixLinkTask?.cancel()
        matrixLinkTask = nil
        pendingMatrixLink = nil
    }
    private func isCurrentMatrixLink(_ request: PendingMatrixLink) -> Bool {
        pendingMatrixLink?.id == request.id && matrix.user?.id == request.accountID
            && matrix.notificationSessionID == request.session && navigationGeneration == request.navigation
            && route == request.route && workspaceID == request.workspaceID && !matrix.isPreview
    }
    @discardableResult private func resumeMatrixLink() -> Bool {
        guard let request = pendingMatrixLink else { return false }
        guard isCurrentMatrixLink(request) else {
            cancelMatrixLink()
            return false
        }
        guard !bootstrapping, !hasModal, !hasNativeModal, !matrix.verification.isPresented else { return true }
        guard matrixLinkTask == nil else { return true }
        matrixLinkTask = Task { @MainActor in
            defer {
                if pendingMatrixLink?.id == request.id { matrixLinkTask = nil }
            }
            do {
                let resolution: MatrixLinkResolution
                switch request.source {
                case .url(let url):
                    guard let resolved = try await matrix.resolveMatrixLink(url) else {
                        throw MatrixServiceError.request("This link isn’t supported.")
                    }
                    resolution = resolved
                case .resolved(let resolved): resolution = resolved
                }
                guard !Task.isCancelled, isCurrentMatrixLink(request), resolution.sessionID == request.session,
                    resolution.accountID == request.accountID
                else { return }
                guard !hasModal, !hasNativeModal, !matrix.verification.isPresented else { return }
                pendingMatrixLink = nil
                matrixLinkTask = nil
                switch resolution.destination {
                case .profile(let userID): openProfile(userID, fallback: nil)
                case .conversation(let roomID, let eventID): selectRoom(roomID, record: true, eventID: eventID)
                case .workspace(let spaceID): openMatrixWorkspace(spaceID)
                case .join(let join): matrixJoin = MatrixJoinSelection(request: join, navigation: request.navigation)
                }
            } catch is CancellationError {
                if pendingMatrixLink?.id == request.id {
                    pendingMatrixLink = nil
                    matrixLinkTask = nil
                }
            } catch {
                guard isCurrentMatrixLink(request), !Task.isCancelled else { return }
                pendingMatrixLink = nil
                matrixLinkTask = nil
                matrix.errorMessage = MatrixService.safeError(error)
            }
        }
        return true
    }
    private func openMatrixWorkspace(_ spaceID: String) {
        navigationGeneration = UUID()
        workspaceID = spaceID
        workspaceInitialized = true
        preferredRoomID = nil
        pendingRoomID = nil
        route = .home
        matrix.setMessageActionThread(rootID: nil)
        threadRoot = nil
        infoOpen = false
        if let first = matrix.rooms.first(where: {
            !$0.isSpace && !$0.isDirect && $0.membership == "join" && $0.spaceIDs.contains(spaceID)
        }) {
            selectRoom(first.id)
        }
    }
    private func finishMatrixJoin(_ destination: MatrixRoomJoinDestination, selection: MatrixJoinSelection) {
        guard matrix.notificationSessionID == selection.request.sessionID,
            matrix.user?.id == selection.request.accountID
        else { return }
        // Joined, but not yet known as a channel or workspace: keep the success state.
        guard let isSpace = destination.isSpace else { return }
        matrixJoin = nil
        guard navigationGeneration == selection.navigation else {
            navigationNotice = destination.warning ?? "Joined. Find it in your sidebar."
            return
        }
        if isSpace {
            openMatrixWorkspace(destination.roomID)
        } else {
            selectRoom(destination.roomID, record: true, eventID: destination.eventID)
        }
        navigationNotice = destination.warning
    }
    private func openActivity(_ item: ActivityItem) {
        if item.kind == .invite {
            if matrix.workspaces.contains(where: { $0.id == item.roomID }) {
                workspaceID = item.roomID
                workspaceInitialized = true
                route = .home
            } else {
                selectRoom(item.roomID)
            }
            return
        }
        if let eventID = item.eventID {
            selectRoom(item.roomID, record: true, eventID: eventID)
        } else {
            selectRoom(item.roomID)
        }
    }
    private func updateActionThreadVisibility() {
        matrix.setMessageActionThread(rootID: threadRoot?.eventID == threadReadyID ? threadReadyID : nil)
    }
    private func startForward(_ target: MessageActionTarget) {
        guard !hasModal, !hasNativeModal, !matrix.verification.isPresented,
            !matrix.isPreview, localReady, pendingRoomID == nil, route == .home, !showPins,
            room?.id == target.message.roomID, room?.membership == "join",
            matrix.isCurrentMessageAction(target)
        else { return }
        forwarding = ForwardSelection(target: target, navigation: navigationGeneration, workspaceID: workspaceID)
    }
    private func cancelStaleForward() {
        guard let selection = forwarding else { return }
        guard selection.navigation == navigationGeneration, selection.workspaceID == workspaceID,
            route == .home, !showPins, pendingRoomID == nil,
            room?.id == selection.target.message.roomID, room?.membership == "join",
            matrix.isCurrentMessageAction(selection.target)
        else {
            forwarding = nil
            return
        }
    }
    private func startCaption(_ target: MessageActionTarget) {
        guard !hasModal, !hasNativeModal, !matrix.verification.isPresented,
            !matrix.isPreview, localReady, pendingRoomID == nil, route == .home, !showPins,
            room?.id == target.message.roomID, room?.membership == "join",
            matrix.isCurrentMessageAction(target)
        else { return }
        mediaCaption = CaptionSelection(target: target, navigation: navigationGeneration, workspaceID: workspaceID)
    }
    private func cancelStaleCaption() {
        guard let selection = mediaCaption else { return }
        guard selection.navigation == navigationGeneration, selection.workspaceID == workspaceID,
            route == .home, !showPins, pendingRoomID == nil,
            room?.id == selection.target.message.roomID, room?.membership == "join",
            matrix.isCurrentMessageAction(selection.target)
        else {
            mediaCaption = nil
            return
        }
    }
    private func startEdit(_ action: MessageActionTarget) {
        let message = action.message
        guard !matrix.isPreview, localReady, pendingRoomID == nil, route == .home, !showPins,
            room?.id == message.roomID, room?.membership == "join", matrix.isCurrentMessageAction(action),
            let target = MessageEditTarget(message: message, surface: action.surface, context: editContext)
        else { return }
        editTarget = target
        editActionTarget = action
        editText = message.body
        cancelReply()
    }
    private func cancelCurrentEdit() {
        editTarget = nil
        editActionTarget = nil
        editText = ""
    }
    private func isCurrentEdit(_ target: MessageEditTarget, context: ComposerContext) -> Bool {
        guard let action = editActionTarget, action.message.eventID == target.message.eventID,
            action.surface == target.surface,
            matrix.isCurrentMessageAction(action)
        else { return false }
        return isCurrentComposer(context) && pendingRoomID == nil && route == .home && !showPins
            && room?.id == target.message.roomID && room?.membership == "join"
            && target.isCurrent(editTarget, in: editContext)
    }
    private func editBinding(_ target: MessageEditTarget, context: ComposerContext) -> Binding<String> {
        Binding(
            get: { isCurrentEdit(target, context: context) ? editText : "" },
            set: { value in
                guard isCurrentEdit(target, context: context) else { return }
                target.write(value, current: editTarget, context: editContext, text: &editText)
            })
    }
    private func editComposer(_ target: MessageEditTarget, room: ChatRoom) -> some View {
        let context = composerContext
        return BindingScope({ editBinding(target, context: context) }) { text in
            MessageComposer(
                text: text, placeholder: "Edit message", members: matrix.members,
                isEditing: true,
                onSend: { body, files in
                    guard files.isEmpty, isCurrentEdit(target, context: context), let action = editActionTarget else {
                        throw CancellationError()
                    }
                    try await matrix.editMessage(action, body: body)
                }, onTyping: { _ in },
                onCancelEdit: {
                    guard isCurrentEdit(target, context: context) else { return }
                    if target.finish(current: &editTarget, context: editContext, text: &editText) {
                        editActionTarget = nil
                    }
                },
                onError: { error in
                    guard isCurrentEdit(target, context: context) else { return }
                    matrix.errorMessage = error
                }, allowsSend: isCurrentEdit(target, context: context)
            )
        }
        .id("edit-\(composerGeneration)-\(target.id)").disabled(!isCurrentEdit(target, context: context))
    }
    private func attachmentBinding(_ address: AttachmentDraftAddress) -> Binding<[URL]> {
        let context = composerContext
        return Binding(
            get: { isCurrentComposer(context) ? attachmentDrafts.queues[address] ?? [] : [] },
            set: { value in
                guard isCurrentComposer(context) else { return }
                attachmentDrafts.set(value, at: address)
            })
    }
    private func sendingBinding(_ key: String) -> Binding<Bool> {
        let context = composerContext
        return Binding(
            get: { isCurrentComposer(context) ? sendingComposers[key] ?? false : false },
            set: { value in
                guard isCurrentComposer(context) else { return }
                sendingComposers[key] = value
            })
    }
    private func draftBinding(_ id: String) -> Binding<String> {
        let context = composerContext
        let target = ComposerDraftTarget(roomID: id, editing: nil)
        return Binding(
            get: {
                guard isCurrentComposer(context) else { return "" }
                return target.read(draft: drafts.conversations[id], editText: editText, editing: nil)
            },
            set: { value in
                guard isCurrentComposer(context) else { return }
                if target.write(value, editing: nil, draft: &drafts.conversations[id], editText: &editText) {
                    saveLocalData()
                }
            })
    }
    private func threadDraftBinding(_ rootID: String, roomID: String) -> Binding<String> {
        let context = composerContext
        let key = ThreadDraftAddress(roomID: roomID, rootID: rootID).id
        let target = ComposerDraftTarget(roomID: roomID, threadRootID: rootID, editing: nil)
        return Binding(
            get: {
                guard isCurrentComposer(context) else { return "" }
                return target.read(draft: drafts.threads[key], editText: editText, editing: nil)
            },
            set: { value in
                guard isCurrentComposer(context) else { return }
                if target.write(value, editing: nil, draft: &drafts.threads[key], editText: &editText) {
                    saveLocalData()
                }
            })
    }
    private func send(
        _ body: String, files: [URL], room: ChatRoom, threadID: String? = nil, context: ComposerContext,
        reply: MessageReplyTarget?
    ) async throws {
        try await sendText(body, room: room, threadID: threadID, context: context, reply: reply)
        for file in files { try await sendFile(file, room: room, threadID: threadID, context: context) }
    }
    private func sendText(
        _ body: String, room: ChatRoom, threadID: String? = nil, context: ComposerContext, reply: MessageReplyTarget?
    ) async throws {
        try assertComposerContext(context)
        guard !matrix.isPreview else { throw MatrixServiceError.preview }
        try assertComposerDestination(room: room, threadID: threadID)
        guard attachmentDrafts.canSend(AttachmentDraftAddress(roomID: room.id, threadRootID: threadID)) else {
            throw MatrixServiceError.request("Check your attachments, then send.")
        }
        guard replyAllowsSend(roomID: room.id, threadID: threadID),
            MessageReplyTarget.authorizes(
                reply, current: replyTarget, owner: replyOwner, roomID: room.id, threadID: threadID),
            reply == nil
                || (route == .home && !showPins && room.id == self.room?.id
                    && matrix.isLiveTimelineReady(roomID: room.id) && !replyOpening && replyError == nil
                    && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        else {
            throw MatrixServiceError.request("The reply changed. Check it and send again.")
        }
        try await matrix.sendMessage(body, threadRootID: threadID, replyToID: reply?.message.eventID, roomID: room.id)
        if isCurrentComposer(context), let reply { reply.finish(current: &replyTarget, owner: replyOwner) }
    }
    private func sendFile(_ file: URL, room: ChatRoom, threadID: String? = nil, context: ComposerContext) async throws {
        try assertComposerContext(context)
        try assertComposerDestination(room: room, threadID: threadID)
        let address = AttachmentDraftAddress(roomID: room.id, threadRootID: threadID)
        try await attachmentDrafts.prepareSend(file, at: address)
        do {
            try assertComposerContext(context)
            try assertComposerDestination(room: room, threadID: threadID)
            try await matrix.uploadFile(file, threadRootID: threadID, roomID: room.id)
        } catch {
            if isCurrentComposer(context) { await attachmentDrafts.didFail(file, at: address) }
            throw error
        }
        if isCurrentComposer(context) { await attachmentDrafts.didSend(file, at: address) }
    }
    private func isCurrentComposer(_ context: ComposerContext) -> Bool {
        localReady && context.generation == composerGeneration && context.identity == composerIdentity
            && composerStateIdentity == context.identity
    }
    private func assertComposerContext(_ context: ComposerContext) throws {
        guard isCurrentComposer(context) else {
            throw MatrixServiceError.request("You signed in again. Reopen the conversation to send.")
        }
    }
    private func assertComposerDestination(room: ChatRoom, threadID: String?) throws {
        guard matrix.selectedRoomID == room.id, pendingRoomID == nil else {
            throw MatrixServiceError.request("Open this conversation to send.")
        }
        if let threadID {
            guard threadReadyID == threadID, threadRoot?.eventID == threadID, threadRoot?.roomID == room.id else {
                throw MatrixServiceError.request("Open the thread to reply.")
            }
        }
    }
    private func canPin(_ room: ChatRoom) -> Bool {
        !matrix.pinnedMessages.isUpdating && !matrix.isPreview
            && (room.canPinMessages ?? (pinPermissionRoomID == room.id && pinPermission))
    }
    private func loadPinPermission(_ room: ChatRoom) async {
        pinPermissionRoomID = nil
        pinPermission = false
        guard !matrix.isPreview, room.membership == "join", room.canPinMessages == nil else { return }
        let identity = composerIdentity
        do {
            let allowed = try await matrix.pinnedMessages.permissionToPin(roomID: room.id)
            guard !Task.isCancelled, composerIdentity == identity, matrix.selectedRoomID == room.id else { return }
            pinPermissionRoomID = room.id
            pinPermission = allowed
        } catch {
            // Pin actions stay unavailable until the SDK can confirm permission.
        }
    }
    private func togglePin(_ message: ChatMessage) {
        let identity = composerIdentity
        let generation = composerGeneration
        let pinned = matrix.rooms.first { $0.id == message.roomID }?.pinnedEventIDs.contains(message.eventID) == true
        Task {
            guard composerIdentity == identity, composerGeneration == generation, !matrix.isPreview else { return }
            do {
                if pinned {
                    _ = try await matrix.pinnedMessages.unpin(eventID: message.eventID, roomID: message.roomID)
                } else {
                    _ = try await matrix.pinnedMessages.pin(eventID: message.eventID, roomID: message.roomID)
                }
            } catch is CancellationError {} catch {
                if composerIdentity == identity, composerGeneration == generation {
                    matrix.errorMessage = MatrixService.safeError(error)
                }
            }
        }
    }
    private func openProfile(_ userID: String, fallback: ChatUser?) {
        guard matrix.user != nil, !matrix.isPreview else { return }
        person = ProfileSelection(id: userID, fallback: fallback)
    }
    private func toggleSave(_ message: ChatMessage) {
        guard localReady else { return }
        guard matrix.isPreview || message.eventID.hasPrefix("$") else {
            matrix.errorMessage = "Wait for the message to send, then save it."
            return
        }
        let reference = SavedMessageReference(roomID: message.roomID, eventID: message.eventID)
        if savedIDs.contains(reference.id) {
            saved.removeAll { $0.id == reference.id }
        } else {
            saved.insert(reference, at: 0)
        }
        saveLocalData()
    }
    private func run(_ action: @escaping () async throws -> Void) {
        let session = matrix.notificationSessionID
        Task {
            guard matrix.notificationSessionID == session else { return }
            do { try await action() } catch is CancellationError {} catch {
                if matrix.notificationSessionID == session { matrix.errorMessage = MatrixService.safeError(error) }
            }
        }
    }
    private func roomsChanged(_ rooms: [ChatRoom]) {
        settleWorkspace()
        cancelStaleThreadOpen()
        cancelStaleForward()
        cancelStaleCaption()
        PlatformIntegration.shared.setBadge(rooms.reduce(0) { $0 + $1.unread })
        if let target = editTarget, room?.id != target.message.roomID || room?.membership != "join" {
            cancelCurrentEdit()
        }
        if let target = replyTarget, room?.id != target.message.roomID || room?.membership != "join" {
            cancelReply()
        }
        openPendingNotification()
        if route == .home && pendingRoomID == nil && invitationResponseID == nil && room == nil {
            let preferred = rooms.first {
                $0.id == preferredRoomID && ($0.isDirect || workspaceID == nil || $0.spaceIDs.contains(workspaceID!))
            }
            if let first = preferred
                ?? rooms.first(where: { !$0.isDirect && (workspaceID == nil || $0.spaceIDs.contains(workspaceID!)) })
            {
                selectRoom(first.id, record: true, keepPendingNotification: true)
            }
        }
    }
    /// Opens the remembered workspace, or the busiest one on first launch, once rooms are known, and moves off
    /// a workspace that is gone.
    private func settleWorkspace() {
        guard !matrix.workspaces.isEmpty || matrix.status == .ready else { return }
        let remembered =
            workspaceInitialized
            ? workspaceID ?? WorkspaceRail.allToken : UserDefaults.standard.string(forKey: "workspace.\(storageKey)")
        let showing = matrix.rooms.first { $0.id == (pendingRoomID ?? matrix.selectedRoomID) }
        let next = WorkspaceRail.choose(
            remembered: remembered, showing: showing, workspaces: matrix.workspaces, rooms: matrix.rooms)
        if next != workspaceID { workspaceID = next }
        workspaceInitialized = true
    }
    private var storageKey: String { matrix.isPreview ? "preview" : matrix.user?.id ?? "signed-out" }
    private var localState: ProtectedLocalState {
        ProtectedLocalState(drafts: drafts.conversations, threadDrafts: drafts.threads, saved: saved)
    }
    private func loadLocalData(retry: Bool = false) {
        if composerStateIdentity != composerIdentity { clearComposerState() }
        preferredRoomID = UserDefaults.standard.string(forKey: "room.\(storageKey)")
        settleWorkspace()
        let identity = composerIdentity
        guard retry || localLoadIdentity != identity else { return }
        localLoadIdentity = identity
        localError = nil
        guard let accountID = identity.userID, !identity.isPreview else {
            localReady = true
            let previous = localTransitionTask
            localTransitionTask = Task {
                await previous?.value
                guard composerIdentity == identity else { return }
                await attachmentDrafts.open(accountID: nil)
            }
            return
        }
        localReady = false
        let generation = UUID()
        localGeneration = generation
        let previous = localTransitionTask
        localTransitionTask = Task { @MainActor in
            await previous?.value
            guard localGeneration == generation, composerIdentity == identity else { return }
            do {
                let access = try await ProtectedLocalStateStore.shared.open(accountID: accountID)
                guard localGeneration == generation, composerIdentity == identity else { return }
                localAccess = access
                localRevision = 0
                drafts.conversations = access.state.drafts
                drafts.threads = access.state.threadDrafts
                saved = access.state.saved
                localReady = true
                localError = nil
                await attachmentDrafts.open(accountID: accountID)
            } catch {
                guard localGeneration == generation, composerIdentity == identity else { return }
                localError = "Couldn’t open your drafts. " + MatrixService.safeError(error)
            }
        }
    }
    /// Capture account, revision and contents before starting asynchronous work.
    private func capturedLocalSave() -> (() async throws -> Void)? {
        guard let access = localAccess, localReady else { return nil }
        localRevision += 1
        let state = localState
        let revision = localRevision
        return { try await ProtectedLocalStateStore.shared.save(state, access: access, revision: revision) }
    }
    private func saveLocalData() {
        guard let save = capturedLocalSave(), let generation = localAccess?.generation else { return }
        let revision = localRevision
        localSaveTask?.cancel()
        localSaveTask = Task { @MainActor in
            do {
                // Coalesce typing bursts; quitting and switching always commit a final snapshot.
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                try await save()
                if localAccess?.generation == generation, localRevision == revision { localError = nil }
            } catch is CancellationError {} catch {
                if localAccess?.generation == generation, localRevision == revision {
                    localError = "Couldn’t save your drafts. " + MatrixService.safeError(error)
                }
            }
        }
    }
    private var logoutOwner: LogoutOwner {
        LogoutOwner(sessionID: matrix.notificationSessionID, userID: matrix.user?.id, isPreview: matrix.isPreview)
    }
    private func beginLogout() {
        let owner = logoutOwner
        Task { @MainActor in
            await logoutRecovery.signOut(
                owner: owner, current: { logoutOwner }, flush: { try await flushLocalData() },
                remote: { try await matrix.logout() }, report: { matrix.errorMessage = MatrixService.safeError($0) })
        }
    }
    private func retryLogout(_ request: LogoutRecoveryRequest) {
        Task { @MainActor in
            await logoutRecovery.retry(
                request, current: { logoutOwner }, flush: { try await flushLocalData() },
                remote: { try await matrix.logout() }, report: { matrix.errorMessage = MatrixService.safeError($0) })
        }
    }
    private func localLogout(_ request: LogoutRecoveryRequest) {
        Task { @MainActor in
            await logoutRecovery.signOutLocally(
                request, current: { logoutOwner }, flush: { try await flushLocalData() },
                local: { try await matrix.logoutLocally() },
                report: { matrix.errorMessage = MatrixService.safeError($0) })
        }
    }

    private func flushLocalData() async throws {
        localSaveTask?.cancel()
        await localTransitionTask?.value
        if let save = capturedLocalSave() { try await save() }
        try await attachmentDrafts.flush()
    }
    private func clearComposerState() {
        localSaveTask?.cancel()
        localSaveTask = nil
        let save = capturedLocalSave()
        let previous = localTransitionTask
        localTransitionTask = Task {
            await previous?.value
            if let save { try? await save() }
            // Account replacement keeps encrypted copies; dispose only temporary plaintext.
            await attachmentDrafts.deactivate()
        }
        localGeneration = UUID()
        localAccess = nil
        localLoadIdentity = nil
        localReady = false
        localError = nil
        drafts.conversations = [:]
        saved = []
        composerGeneration = UUID()
        composerStateIdentity = composerIdentity
        drafts.threads = [:]
        sendingComposers = [:]
        invitationResponseID = nil
        navigationNotice = nil
        visibleBottomRoomID = nil
        threadReadViewport = ThreadReadViewport()
        readHold = ReadStateHold()
        cancelCurrentEdit()
        cancelReply()
        forwarding = nil
        mediaCaption = nil
        navigationGeneration = UUID()
        pendingRoomID = nil
        preferredRoomID = nil
        matrix.setMessageActionThread(rootID: nil)
        threadRoot = nil
        threadReadyID = nil
        openingThreadID = nil
        threadLoadError = nil
        unreadResumeEventID = nil
    }
    private func resetUI() {
        cancelThreadOpen()
        cancelMatrixLink()
        matrixJoin = nil
        previews.close()
        previews.setSession(matrix.notificationSessionID)
        clearComposerState()
        workspaceID = nil
        workspaceInitialized = false
        infoOpen = false
        showPins = false
        pinPermissionRoomID = nil
        pinPermission = false
        route = .home
        history = []
        historyIndex = -1
        sidebarSearch = ""
        modals.current = nil
        publicDirectory = nil
        showRecovery = false
        creation = nil
        inviteTargetRoomID = nil
        person = nil
        roomDetails = nil
        roomNotifications = nil
        loadLocalData()
    }
    private func closeThread() {
        navigationGeneration = UUID()
        if replyTarget?.threadID != nil { cancelReply() }
        matrix.setMessageActionThread(rootID: nil)
        threadRoot = nil
        threadReadyID = nil
        openingThreadID = nil
    }
    /// Slack's plain-key shortcuts from a composer; false lets the key do its usual thing.
    private func conversationKey(_ action: ConversationKeys.Action, room: ChatRoom, threadRootID: String?) -> Bool {
        switch action {
        case .markRead: markReadState(room, unread: false)
        case .markAllRead: handleMenu("mark-all-read")
        case .editLastMessage:
            let messages = threadRootID == nil ? matrix.messages : matrix.threadMessages
            guard let message = ConversationKeys.lastEditable(messages, userID: matrix.user?.id),
                let target = matrix.captureMessageAction(
                    message: message, surface: threadRootID.map { .thread(rootID: $0) } ?? .conversation)
            else { return false }
            startEdit(target)
            return editTarget != nil
        }
        return true
    }
    private func handleMenu(_ action: String) {
        // Esc reaches here when nothing in the modal took it: it closes the modal, as in Slack.
        if modals.current != nil, action == "mark-read" { return closeModal() }
        guard !hasModal, !hasNativeModal, !matrix.verification.isPresented else { return }
        if action == "shortcuts" {
            modals.current = .shortcuts
            return
        }
        if action == "preferences" {
            Performance.start(.preferencesOpen)
            modals.current = .preferences
            return
        }
        guard matrix.user != nil else { return }
        if action.hasPrefix("search") { Performance.start(.searchOpen) }
        switch action {
        case "search": modals.current = .search(messages: false, roomID: nil)
        case "search-messages": modals.current = .search(messages: true, roomID: nil)
        case "search-conversation":
            modals.current = .search(messages: true, roomID: route == .home ? room?.id : nil)
        case "new-message": creation = .directMessage
        case "new-channel": creation = .channel
        case "back": navigateHistory(-1)
        case "forward": navigateHistory(1)
        case "threads": route = .threads
        case "dms": route = .directMessages
        case "activity": route = .activity
        case "later": route = .saved
        case "people": route = .directory
        case "browse-channels": presentPublicDirectory()
        case _ where action.hasPrefix("workspace-"):
            let rail = WorkspaceRail.entries(workspaces: matrix.workspaces, rooms: matrix.rooms)
            guard let index = Int(action.dropFirst("workspace-".count)), rail.indices.contains(index - 1) else {
                return
            }
            Performance.start(.workspaceSwitch)
            workspaceID = rail[index - 1]?.id
            workspaceInitialized = true
            route = .home
        case "toggle-sidebar": sidebarHidden.toggle()
        case "toggle-pane":
            guard route == .home, room != nil else { return }
            if threadRoot != nil {
                closeThread()
            } else {
                infoOpen.toggle()
                if infoOpen { Task { await matrix.loadMembers() } }
            }
        case "mark-read": if route == .home, let room { _ = conversationKey(.markRead, room: room, threadRootID: nil) }
        case "mark-all-read":
            for room in matrix.rooms where room.membership == "join" && room.hasUnread {
                markReadState(room, unread: false)
            }
        case "react-last":
            guard route == .home, !showPins, editTarget == nil,
                let last = matrix.messages.last(where: { $0.sendState == "sent" && !$0.isRedacted })
            else { return }
            lastMessageReaction = matrix.captureMessageAction(message: last, surface: .conversation)
        case "previous-conversation", "next-conversation", "previous-unread", "next-unread":
            let direction = action.hasPrefix("previous") ? -1 : 1
            let rooms = matrix.rooms.filter {
                sidebarSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(sidebarSearch)
            }
            if let id = ConversationNavigation.target(
                rooms: rooms, currentID: pendingRoomID ?? matrix.selectedRoomID, workspaceID: workspaceID,
                unreadOnly: action.hasSuffix("unread"), direction: direction)
            {
                selectRoom(id)
            }
        default: break
        }
    }
}

/// The open conversation as the window shows it: hidden while another workspace is on screen.
@MainActor private func shownRoom(_ matrix: MatrixService, workspaceID: String?) -> ChatRoom? {
    matrix.selectedRoom.flatMap { $0.isDirect || workspaceID == nil || $0.spaceIDs.contains(workspaceID!) ? $0 : nil }
}

/// What the read policies need from the window's own state.
private struct ReadInputs {
    var route: AppRoute
    var showPins: Bool
    var workspaceID: String?
    var visibleBottomRoomID: String?
    var windowCanRead: Bool
    var hasPresentedSheet: Bool
    var threadRootID: String?
    var threadReadyID: String?
    var openingThreadID: String?
    var threadLoadFailed: Bool
    var localReady: Bool
    var threadReadViewport: ThreadReadViewport
    var readHold: ReadStateHold

    @MainActor static var hasNativeModal: Bool {
        NSApp.modalWindow != nil
            || NSApp.windows.contains { $0.frameAutosaveName == "SlatrixMainWindow" && $0.attachedSheet != nil }
    }

    @MainActor func readContext(_ matrix: MatrixService) -> ReadStateContext {
        let latest = matrix.messages.last(where: { $0.eventID.hasPrefix("$") })
        let visible = windowCanRead && PlatformIntegration.shared.conversationWindowIsVisible
        return ReadStateContext(
            accountID: matrix.user?.id, sessionGeneration: matrix.notificationSessionID,
            timelineGeneration: matrix.timelineSelectionID, roomID: matrix.selectedRoomID ?? "",
            selectedRoomID: matrix.selectedRoomID,
            latestVisibleEventID: latest?.kind == "m.room.encrypted" ? nil : latest?.eventID,
            isPreview: matrix.isPreview, isJoined: shownRoom(matrix, workspaceID: workspaceID)?.membership == "join",
            isMainTimeline: route == .home && !showPins,
            isLiveTimeline: matrix.focusedEventID == nil && matrix.status == .ready,
            isAtBottom: visibleBottomRoomID == matrix.selectedRoomID && visibleBottomRoomID != nil,
            isWindowActive: visible, isWindowVisible: visible, isWindowUnoccluded: visible,
            hasModal: hasPresentedSheet || Self.hasNativeModal || matrix.verification.isPresented
        )
    }

    @MainActor func threadReadContext(_ matrix: MatrixService) -> ThreadReadContext {
        let identity = matrix.threadReadIdentity
        let latest = matrix.threadMessages.last(where: { $0.eventID.hasPrefix("$") })
        let visible = windowCanRead && PlatformIntegration.shared.conversationWindowIsVisible
        return ThreadReadContext(
            identity: identity, eventID: latest?.kind == "m.room.encrypted" ? nil : latest?.eventID,
            isPresented: route == .home && threadRootID == identity?.rootID
                && shownRoom(matrix, workspaceID: workspaceID)?.id == identity?.roomID,
            isReady: identity != nil && localReady && matrix.status == .ready && threadReadyID == identity?.rootID
                && openingThreadID == nil && !threadLoadFailed,
            isAtBottom: threadReadViewport.isAtBottom(identity), isWindowActive: visible, isWindowVisible: visible,
            isWindowUnoccluded: visible,
            hasModal: hasPresentedSheet || Self.hasNativeModal || matrix.verification.isPresented,
            manualUnreadHeld: readHold.blocks(readContext(matrix)))
    }
}

/// Marks what the reader can see as read. Apart from the window, so a new message reruns only these checks.
private struct ReadTracking: View {
    let matrix: MatrixService
    let inputs: ReadInputs
    let onReadContext: (ReadStateContext) -> Void
    let onThreadIdentity: (ThreadReadIdentity?) -> Void
    let acknowledgeTimeline: () async -> Void
    let acknowledgeThread: () async -> Void
    var body: some View {
        let context = inputs.readContext(matrix)
        Color.clear
            .onChange(of: context) { _, context in onReadContext(context) }
            .task(id: ReadStatePolicy.automaticTarget(context, hold: inputs.readHold)) { await acknowledgeTimeline() }
            .onChange(of: matrix.threadReadIdentity) { _, identity in onThreadIdentity(identity) }
            .task(id: ThreadReadPolicy.target(inputs.threadReadContext(matrix))) { await acknowledgeThread() }
    }
}

/// Follows the room list for the window, so a change to a room reruns these checks, not the window's body.
private struct RoomListWatcher: View {
    let matrix: MatrixService
    let onRooms: ([ChatRoom]) -> Void
    let onWorkspaces: () -> Void
    var body: some View {
        Color.clear
            .onChange(of: matrix.rooms) { _, rooms in onRooms(rooms) }
            .onChange(of: matrix.workspaces) { _, _ in onWorkspaces() }
    }
}

private struct HistoryMenu: View {
    let matrix: MatrixService
    let history: [String]
    let onSelect: (Int) -> Void
    @Environment(\.metrics) private var m
    var body: some View {
        Menu {
            ForEach(Array(history.enumerated()).reversed(), id: \.offset) { index, id in
                Button(matrix.rooms.first { $0.id == id }?.name ?? "Conversation") { onSelect(index) }
            }
        } label: {
            Image(systemName: "clock").font(m.font(.title)).frame(width: m.iconButton, height: m.iconButton)
        }.menuStyle(.borderlessButton).frame(width: m.iconButton + m.sp4).help("Recent conversations")
    }
}

private struct ConnectionBanner: View {
    let matrix: MatrixService
    let onRetry: () -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        if let message = matrix.connectionErrorMessage {
            HStack(spacing: m.sp12) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(message).font(m.font(.meta)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: m.sp8)
                if matrix.canRetryConnection || matrix.isRetryingConnection {
                    Button(action: onRetry) {
                        HStack(spacing: m.sp8) {
                            if matrix.isRetryingConnection { ProgressView().controlSize(.mini) }
                            Text(matrix.isRetryingConnection ? "Reconnecting…" : "Retry")
                        }
                    }.buttonStyle(.bordered).controlSize(.small).disabled(matrix.isRetryingConnection)
                }
            }.padding(m.sp12).modifier(Toast(colors: appearance.colors))
        }
    }
}

private struct ErrorToast: View {
    let matrix: MatrixService
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        if let error = matrix.errorMessage {
            InlineErrorView(message: error, dismiss: { matrix.errorMessage = nil })
                .modifier(Toast(colors: appearance.colors))
        }
    }
}

/// Who is typing in the open conversation, on a line of its own so typing redraws nothing else.
private struct TypingLine: View {
    let matrix: MatrixService
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    private var label: String {
        let names = matrix.typingUsers
        if names.count == 1 { return names[0] + " is typing…" }
        if names.count == 2 { return names.joined(separator: " and ") + " are typing…" }
        return "Several people are typing…"
    }
    var body: some View {
        HStack {
            if !matrix.typingUsers.isEmpty { Text(label) }
            Spacer()
        }.font(m.font(.caption)).foregroundStyle(appearance.colors.muted).padding(.horizontal, m.sp24)
            .layoutIsolated().frame(height: m.sp24)
    }
}

private struct ThreadProgress: View {
    let matrix: MatrixService
    let active: Bool
    var body: some View {
        DelayedProgress(active: active, hasContent: matrix.threadMessages.count > 1, interval: .threadLoading)
    }
}

private struct RoomName: View {
    let matrix: MatrixService
    let roomID: String
    var body: some View { Text(matrix.rooms.first { $0.id == roomID }?.name ?? "Conversation") }
}

/// Every direct message, for the DMs page.
private struct RoomDirectory: View {
    let matrix: MatrixService
    let onSelect: (String) -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(matrix.rooms.filter(\.isDirect)) { room in
                    Button {
                        onSelect(room.id)
                    } label: {
                        HStack(spacing: m.sp12) {
                            AvatarView(name: room.name, size: m.avatar, matrix: matrix, source: room.avatarURL)
                            VStack(alignment: .leading, spacing: m.sp4) {
                                Text(room.name).font(m.font(.body, .semibold))
                                Text(
                                    room.topic.isEmpty
                                        ? room.isDirect ? "Direct message" : "\(room.memberCount) members" : room.topic
                                ).font(m.font(.meta)).foregroundStyle(colors.muted).lineLimit(1)
                            }
                            Spacer()
                            if room.hasUnread {
                                Text(
                                    room.unreadMessages > 0 || room.unread > 0
                                        ? "\(max(room.unreadMessages, room.unread))" : "•"
                                ).font(m.font(.caption, .semibold)).padding(m.sp4).background(
                                    colors.selection, in: Circle()
                                ).accessibilityLabel("Unread conversation")
                            }
                            Image(systemName: "chevron.right").font(m.font(.caption)).foregroundStyle(colors.muted)
                        }.padding(m.sp20).contentShape(Rectangle())
                    }.buttonStyle(.row)
                    Divider().overlay(colors.border).padding(.leading, m.sp20 + m.avatar + m.sp12)
                }
            }
        }
    }
}

/// Makes a binding inside its own body: SwiftUI reads a binding when it compares a view's inputs, and what the
/// binding reads, such as a draft that changes with every keystroke, then redraws whichever view made it.
private struct BindingScope<Value, Content: View>: View {
    let binding: () -> Binding<Value>
    @ViewBuilder let content: (Binding<Value>) -> Content
    init(_ binding: @escaping () -> Binding<Value>, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        self.binding = binding
        self.content = content
    }
    var body: some View { content(binding()) }
}

/// Closes Quick Look once its message leaves what is shown; on its own, so new messages do not redraw the window.
private struct PreviewInvalidation: View {
    let matrix: MatrixService
    let previews: AttachmentPreviewController
    var body: some View {
        Color.clear
            .onChange(of: matrix.messages) { previews.invalidateIfNeeded() }
            .onChange(of: matrix.threadMessages) { previews.invalidateIfNeeded() }
            .onChange(of: matrix.sharedFiles.items) { previews.invalidateIfNeeded() }
            .onChange(of: matrix.rooms) { previews.invalidateIfNeeded() }
    }
}

/// A transient state floating over content: it never moves what is under it.
private struct Toast: ViewModifier {
    @Environment(\.metrics) private var m
    let colors: AppColors
    func body(content: Content) -> some View {
        content.background(colors.raised).clipShape(RoundedRectangle(cornerRadius: m.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}
