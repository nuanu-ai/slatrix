import AppKit
import Combine
import QuickLook
import SwiftUI

/// What the window shows. The window never sits on `directMessages`: that is the sidebar's DMs list, beside a
/// conversation on `home`.
enum AppRoute: String, CaseIterable {
    case home, directMessages, activity, files, saved, threads, drafts, directory, search, channels
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
        case .search: "Search"
        case .channels: "Channels"
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
        case .search: "magnifyingglass"
        case .channels: "number"
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
    /// The sidebar column lists direct messages, as Slack's DMs view does, while the one open shows beside it.
    @State private var directMessagesColumn = false
    @State private var directMessageSearch = ""
    @State private var unreadDirectMessagesOnly = false
    @AppStorage("layout.sidebarWidth") private var preferredSidebarWidth = 280.0
    @AppStorage("layout.sidebarHidden") private var sidebarHidden = false
    /// The rail and sidebar over the conversation while they are collapsed.
    @State private var sidebarDrawer = false
    @State private var collapsedSections: Set<String> = []
    /// The dragged thread and details pane width at 100% zoom; 0 until dragged, for each pane's own width.
    @AppStorage("layout.paneWidth") private var preferredPaneWidth = 0.0
    @State private var widths = PaneWidths()
    @State private var arrangement = SidebarLayout.arrangement(availableWidth: 1_440)
    /// Preferences, ⌘K and the shortcuts list, shown in the window like Slack's. Not read by this body, so opening
    /// one re-renders only the modal host, not the whole window.
    @State private var modals = InWindowModal()
    @State private var searchBar = SearchBar()
    @State private var recentSearches: [String] = []
    /// Any modal at all, such as a confirmation the timeline opened; read outside the body only.
    @State private var modalShown = false
    @State private var showRecovery = false
    @State private var editingProfile = false
    @State private var creation: CreationKind?
    @State private var inviteTargetRoomID: String?
    /// Anchored cards such as the emoji picker; like `modals`, read only by its host.
    @State private var popovers = Popovers()
    /// The full profile in the right-hand pane, over the thread or details until closed.
    @State private var profilePane: ProfileSelection?
    @State private var roomDetails: DetailsSelection?
    @State private var roomNotifications: DetailsSelection?
    @State private var forwarding: ForwardSelection?
    @State private var mediaCaption: CaptionSelection?
    @State private var matrixJoin: MatrixJoinSelection?
    @State private var pendingMatrixLink: PendingMatrixLink?
    @State private var matrixLinkTask: Task<Void, Never>?
    @State private var channelDetails: ChannelDetailsSelection?
    @State private var leaving: ChatRoom?
    @State private var toasts = Toasts()
    @State private var channelPanel: ChannelPanel?
    /// The screen a conversation was picked on, which stays up until that conversation can replace it.
    @State private var pickedFrom: Screen?
    @State private var pinPermissionRoomID: String?
    @State private var pinPermission = false
    @State private var threadRoot: ChatMessage?
    /// Whether messages sit under the conversation's and the thread's headers, which then draw their lines.
    @State private var conversationContentAbove = false
    @State private var threadContentAbove = false
    /// Threads left open in a conversation, by room, for this session: coming back opens them again, as in Slack.
    @State private var leftThreads: [String: ChatMessage] = [:]
    /// The thread whose "Also send to #channel" is checked; another thread starts unchecked, as in Slack.
    @State private var channelCopyRootID: String?
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
    @State private var viewer = MediaViewerState()
    @StateObject private var attachmentDrafts = AttachmentDraftController()
    @State private var invitationResponseID: String?
    @State private var navigationNotice: String?
    @State private var sendingComposers: [String: Bool] = [:]
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
    /// Threads and profiles share one pane width, as in Slack.
    private static let paneWidth: CGFloat = 400
    /// Where the window buttons end, in window points: inset as far as they sit from the top, then AppKit's three
    /// 14-point buttons 20 points apart.
    private var windowButtonsWidth: CGFloat { (m.paneHeader - 14) / 2 + 54 }
    static let searchWidth: CGFloat = 180
    private var paneOpen: Bool { profilePane != nil || (room != nil && (threadRoot != nil || channelPanel != nil)) }
    /// Whether an open pane sits beside the conversation; otherwise it lies over it.
    private var paneBeside: Bool { sidebarCollapsed ? arrangement.paneFitsAlone : arrangement.paneFitsBesideSidebar }
    /// The rail and sidebar leave for a drawer: hidden by hand, or no room beside a readable conversation and an
    /// open pane.
    private var sidebarCollapsed: Bool {
        sidebarHidden || !(paneOpen ? arrangement.sidebarFitsBesidePane : arrangement.sidebarFits)
    }
    // The widths below read `widths`, which changes with every step of a resize, so only the frames and controls
    // that need a width call them; the window's body reads `arrangement`, which changes only at a threshold.
    /// The thread or details pane width at 100% zoom, nil when it covers the conversation.
    private func paneWidth(_ widths: PaneWidths) -> CGFloat? {
        guard paneOpen else { return nil }
        return SidebarLayout.paneWidth(
            preferred: widths.pane ?? CGFloat(preferredPaneWidth), ideal: Self.paneWidth,
            availableWidth: widths.available / m.zoom, sidebarShown: !sidebarCollapsed)
    }
    /// Pane width plus its divider, at 100% zoom.
    private func occupiedPaneWidth(_ widths: PaneWidths) -> CGFloat {
        paneWidth(widths).map { $0 + SidebarLayout.handleWidth } ?? 0
    }
    private func sidebarWidth(_ widths: PaneWidths) -> CGFloat {
        m(
            SidebarLayout.effective(
                preferred: widths.sidebar ?? SidebarLayout.validatedPreferred(preferredSidebarWidth),
                availableWidth: widths.available / m.zoom, inspectorWidth: occupiedPaneWidth(widths)))
    }
    private func searchFits(_ widths: PaneWidths) -> Bool {
        let available = widths.available / m.zoom
        // Beside the sidebar, or after the window buttons and the button that brings it back.
        let leading =
            sidebarCollapsed
            ? (windowButtonsWidth + m.control + m.sp12) / m.zoom
            : (sidebarWidth(widths) + m.sidebarInset) / m.zoom + SidebarLayout.handleWidth
        return SidebarLayout.searchFits(
            availableWidth: available, toolbarWidth: available - leading - occupiedPaneWidth(widths))
    }
    private var layoutMeasurement: some View {
        GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size.width / m.zoom, initial: true) { _, width in
                widths.available = geometry.size.width
                let next = SidebarLayout.arrangement(availableWidth: width)
                if next != arrangement { arrangement = next }
            }
        }
    }

    private var room: ChatRoom? { shownRoom(matrix, workspaceID: workspaceID) }
    private struct Screen {
        var route: AppRoute
    }
    private var screen: Screen {
        ConversationNavigation.shown(
            Screen(route: route), from: pickedFrom, showing: room?.id, opening: pendingRoomID)
    }
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
    private var savedIDs: Set<String> { Set(matrix.savedMessages.list.saved.map(\.id)) }
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
        let sourceRoute: AppRoute
        let selectedRoomID: String?
    }
    private struct ProfileSelection: Identifiable {
        var id: String
        var fallback: ChatUser?
    }
    private struct DetailsSelection: Identifiable { var id: String }
    private struct ChannelDetailsSelection: Identifiable {
        let room: ChatRoom
        let tab: RoomInfoView.Tab
        var id: String { room.id }
    }
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
        showRecovery || creation != nil || channelDetails != nil || leaving != nil
            || roomDetails != nil || roomNotifications != nil || forwarding != nil
            || mediaCaption != nil || matrixJoin != nil || logoutConfirmation
            || logoutRecovery.request != nil || logoutRecovery.isBusy
    }
    private var hasNativeModal: Bool { ReadInputs.hasNativeModal }

    /// Every modal, for actions that must wait for all of them; read outside the body only.
    private var hasModal: Bool { hasPresentedSheet || modals.current != nil || modalShown }

    var body: some View {
        ModalHost(
            onCovered: { shown in
                modalShown = shown
                // A notification that arrived while a modal was open opens once it closes.
                if !shown { openPendingNotification() }
            }
        ) {
            PopoverHost(popovers: popovers) {
                windowContent.environment(popovers).environment(toasts)
            } card: { kind in
                popoverCard(kind)
            }
            .modal(
                item: Binding(get: { modals.current }, set: { if $0 == nil { closeModal() } }),
                closesOnClickOutside: true, content: modal)
        }
        .overlay {
            MediaViewer(matrix: matrix, viewer: viewer, onForward: startForward)
        }
        // Outside the modal host, so modals open links and show mentions as the window does.
        .environment(\.openURL, OpenURLAction(handler: handleOpenURL))
        .environment(\.mentions, MentionContext(me: matrix.user?.id))
    }

    @ViewBuilder private func modal(_ kind: InWindowModal.Kind) -> some View {
        switch kind {
        case .preferences(let tab):
            PreferencesView(
                matrix: matrix, onClose: closeModal,
                onLogout: {
                    closeModal()
                    logoutConfirmation = true
                },
                // Preferences sits above every other modal, so it steps aside for the one it opens.
                onRecovery: {
                    closeModal()
                    showRecovery = true
                },
                onEditProfile: {
                    closeModal()
                    editingProfile = true
                }, tab: tab
            ).onAppear { Performance.finishOnScreen(.preferencesOpen) }
        case .switcher:
            QuickSwitcherView(
                matrix: matrix, visited: history,
                onSelect: {
                    selectRoom($0)
                    closeModal()
                }, onMatrixLink: enqueueMatrixLink, onClose: closeModal
            ).onAppear { Performance.finishOnScreen(.searchOpen) }
                // Slack's switcher hangs below the title bar, not centered.
                .modalSurface().frame(maxHeight: .infinity, alignment: .top).padding(.top, m(112))
        case .shortcuts: KeyboardShortcutsView(onClose: closeModal)
        }
    }

    @ViewBuilder private func popoverCard(_ kind: Popovers.Kind) -> some View {
        switch kind {
        case .emoji(let pick):
            EmojiPicker(recent: matrix.recentEmoji) { emoji in
                popovers.close()
                pick.action(emoji)
            }
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
                        DelayedProgress()
                        Text("Signing out…").font(m.font(.body))
                    }
                    .padding(m.sp24).background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                }
            }
            .background(ViewerInvalidation(matrix: matrix, viewer: viewer))
            .background(layoutMeasurement)
    }

    private var readAwareContent: some View {
        notificationAwareContent
            .onAppear {
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
                // Sync doesn't say when your profile changes elsewhere, so coming back to Slatrix checks.
                if notification.name == NSApplication.didBecomeActiveNotification {
                    Task { await matrix.refreshOwnProfile() }
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
            .onChange(of: sidebarCollapsed) { _, _ in sidebarDrawer = false }
            // Saved here or merged from another device, it reaches the vault either way.
            .onChange(of: matrix.savedMessages.list) { _, _ in saveLocalData() }
            .onChange(of: route) { _, next in
                // DMs picked in the drawer keeps it open on the list.
                if !(next == .home && directMessagesColumn) { sidebarDrawer = false }
                if let request = pendingMatrixLink, request.route != next { cancelMatrixLink() }
                if next != .home {
                    directMessagesColumn = false
                    cancelCurrentEdit()
                    cancelReply()
                    channelPanel = nil
                    navigationGeneration = UUID()
                    pendingRoomID = nil
                    matrix.setMessageActionThread(rootID: nil)
                    threadRoot = nil
                    threadReadyID = nil
                    openingThreadID = nil
                }
            }
            .onChange(of: threadRoot?.eventID) { _, id in
                updateActionThreadVisibility()
                if id != nil {
                    profilePane = nil
                    channelPanel = nil
                }
            }
            .onChange(of: threadReadyID) { _, _ in updateActionThreadVisibility() }
            .onChange(of: navigationGeneration) { _, _ in
                popovers.close()
                cancelStaleThreadOpen()
                cancelStaleForward()
                cancelStaleCaption()
            }
            .onChange(of: matrix.timelineSelectionID) { _, _ in cancelStaleThreadOpen() }
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
            .task(
                id: LaterReminderInputs(
                    list: matrix.savedMessages.list, accountID: reminderAccount,
                    preview: appearance.notificationPreview)
            ) { await syncLaterReminders() }
    }

    private struct LaterReminderInputs: Equatable {
        var list: SavedMessages
        var accountID: String?
        var preview: Bool
    }
    /// Who Later's reminders notify: nobody in the preview or with notifications off.
    private var reminderAccount: String? {
        appearance.notifications && !matrix.isPreview ? matrix.user?.id : nil
    }
    private func syncLaterReminders() async {
        let preview = appearance.notificationPreview
        let account = reminderAccount
        await platform.laterReminders.sync(matrix.savedMessages.list, accountID: account) { item in
            guard let account,
                let target = MatrixNotificationTarget(accountID: account, roomID: item.roomID, eventID: item.eventID)
            else { return nil }
            guard preview else {
                return DesktopMessageNotification(target: target, title: "Slatrix", body: "Reminder", playSound: true)
            }
            let room = matrix.rooms.first { $0.id == item.roomID }
            var (title, body) = (room?.name ?? "Slatrix", "Reminder")
            if let message = try? await matrix.messagePreview(roomID: item.roomID, eventID: item.eventID) {
                let text = DesktopMessageNotification.message(
                    room: room?.name ?? "", sender: message.senderName, direct: room?.isDirect ?? false,
                    body: message.body)
                (title, body) = (text.title, "Reminder: \(text.text)")
            }
            return DesktopMessageNotification(target: target, title: title, body: body, playSound: true)
        }
    }

    private var linkPresentedContent: some View {
        mainContent
            .modal(item: $matrixJoin) { selection in
                MatrixRoomJoinView(
                    matrix: matrix, request: selection.request,
                    onJoined: { finishMatrixJoin($0, selection: selection) }, onClose: { matrixJoin = nil })
            }
    }

    private var presentedContent: some View {
        linkPresentedContent
            .modal(item: $channelDetails, closesOnClickOutside: true) { selection in
                RoomInfoView(
                    matrix: matrix, room: selection.room, tab: selection.tab, onClose: { channelDetails = nil },
                    onInvite: { presentCreation(.invite) }, onRecovery: { showRecovery = true },
                    onOpenProfile: { id, fallback in
                        channelDetails = nil
                        profilePane = ProfileSelection(id: id, fallback: fallback)
                    },
                    onEditDetails: { roomDetails = DetailsSelection(id: selection.room.id) },
                    onNotifications: { roomNotifications = DetailsSelection(id: selection.room.id) })
            }
            .modal(item: $creation) { kind in
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
                    })
            }
            .modal(isPresented: $showRecovery) {
                EncryptionRecoveryView(matrix: matrix, onClose: { showRecovery = false })
            }
            .modal(isPresented: $editingProfile) {
                ProfileEditor(matrix: matrix, onClose: { editingProfile = false })
            }
            .modal(item: $roomDetails) { selection in
                RoomDetailsEditor(matrix: matrix, roomID: selection.id, onClose: { roomDetails = nil })
            }
            .modal(item: $leaving) { room in
                ConfirmModal(
                    title: "Leave \(room.name)?", message: "You may need an invitation to rejoin.", action: "Leave",
                    onConfirm: {
                        leaving = nil
                        run { try await matrix.leaveRoom(room.id) }
                    }, onCancel: { leaving = nil })
            }
            .modal(item: $roomNotifications) { selection in
                RoomNotificationSettingsView(matrix: matrix, roomID: selection.id, onClose: { roomNotifications = nil })
            }
            .modal(item: $forwarding) { selection in
                ForwardMessageView(
                    matrix: matrix, target: selection.target,
                    onClose: {
                        guard forwarding?.id == selection.id else { return }
                        forwarding = nil
                    })
            }
            .modal(item: $mediaCaption) { selection in
                MediaCaptionEditor(
                    matrix: matrix, target: selection.target,
                    onClose: {
                        guard mediaCaption?.id == selection.id else { return }
                        mediaCaption = nil
                    })
            }
            .modifier(VerificationPresentation(service: matrix.verification, enabled: !hasPresentedSheet))
            .modal(item: Binding(get: { logoutRecovery.request }, set: { if $0 == nil { logoutRecovery.cancel() } })) {
                request in
                LogoutRecoveryView(
                    controller: logoutRecovery, request: request,
                    onRetry: { retryLogout(request) }, onLocalSignOut: { localLogout(request) },
                    onCancel: logoutRecovery.cancel)
            }
            .modal(isPresented: $logoutConfirmation) {
                ConfirmModal(
                    title: "Sign out of Slatrix?",
                    message: "You’ll need your recovery key to read encrypted messages when you sign back in.",
                    action: "Sign out",
                    onConfirm: {
                        logoutConfirmation = false
                        if !logoutRecovery.isBusy { beginLogout() }
                    }, onCancel: { logoutConfirmation = false })
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
                            !(platform.conversationWindowIsVisible && route == .home
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
        Group {
            if bootstrapping {
                DelayedProgress(interval: .appLoading).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        if !sidebarCollapsed {
                            sidebar().padding([.leading, .vertical], m.sidebarInset).transition(.move(edge: .leading))
                            WithWidths(widths) { widths in
                                ResizeHandle(
                                    currentWidth: sidebarWidth(widths), onChange: resizeSidebar,
                                    onCommit: commitSidebarWidth,
                                    onReset: {
                                        widths.sidebar = nil
                                        preferredSidebarWidth = Double(SidebarLayout.defaultWidth)
                                    })
                            }
                        }
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                if screen.route == .home {
                                    if let room {
                                        channelContent(room)
                                    } else if !matrix.roomsLoaded {
                                        toolbar { EmptyView() }
                                        syncingView
                                    } else {
                                        toolbar { EmptyView() }
                                        noRoomsView
                                    }
                                } else {
                                    collectionContent(screen.route)
                                }
                            }
                            // A composer that grows or a message that arrives lays out this column, not the window.
                            .layoutIsolated()
                            // Banners float over the conversation instead of pushing it down.
                            .overlay(alignment: .top) { banners.padding(.top, m.paneHeader) }
                            // Too narrow to sit beside: the pane lies over the conversation's right side.
                            .overlay(alignment: .trailing) {
                                if paneOpen && !paneBeside {
                                    inspector(room).frame(maxWidth: m(Self.paneWidth))
                                        .elevation(.e3, cornerRadius: 0)
                                }
                            }
                            if paneOpen && paneBeside {
                                WithWidths(widths) { widths in
                                    ResizeHandle(
                                        pane: .trailing,
                                        label: profilePane != nil
                                            ? "Profile width" : threadRoot != nil ? "Thread width" : "Details width",
                                        currentWidth: m(paneWidth(widths) ?? Self.paneWidth), onChange: resizePane,
                                        onCommit: commitPaneWidth,
                                        onReset: {
                                            widths.pane = nil
                                            preferredPaneWidth = 0
                                        })
                                }
                                Sized(widths, width: { m(paneWidth($0) ?? Self.paneWidth) }) {
                                    inspector(room).layoutIsolated()
                                }
                            }
                        }.frameCard(colors.theme.framed, leading: sidebarCollapsed)
                    }
                    .overlay(alignment: .leading) { drawer }
                    .animation(Motion.pane, value: sidebarCollapsed)
                }
            }
        }
        .coordinateSpace(.named(SearchBar.space))
        .focusedSceneValue(\.sidebarShown, !sidebarCollapsed || sidebarDrawer)
        .focusedSceneValue(\.rightPaneShown, paneOpen)
        .overlay(alignment: .topLeading) {
            SearchMenu(
                bar: searchBar, matrix: matrix, recents: recentSearches, visited: history,
                top: m.paneHeader + (colors.theme.framed ? m.sidebarInset : 0), onPick: pickSearch)
        }
        // The window moves by its top edge wherever nothing there takes the click, and its buttons sit centered in it,
        // level with the toolbar, which a frame theme insets.
        .background(alignment: .top) {
            WindowDragArea().frame(height: m.paneHeader + (colors.theme.framed ? 2 * m.sidebarInset : 0))
                .background(WindowButtonsCentering())
        }
        .background(FrameBackground(colors: colors, gradient: appearance.windowGradient))
        .foregroundStyle(colors.textBody).ignoresSafeArea(.container, edges: .top)
    }

    /// What needs attention until it resolves, across the top of the pane: the connection, waits that can be
    /// cancelled, and errors.
    private var banners: some View {
        VStack(spacing: 0) {
            ConnectionBanner(matrix: matrix, onRetry: retryConnection)
            if pendingMatrixLink != nil {
                Banner(text: "Opening…", tone: .neutral) {
                    Button("Cancel") {
                        cancelMatrixLink()
                        openPendingNotification()
                    }
                }.loadingInterval(.linkLoading)
            }
            if let request = pendingThreadOpen, isCurrentThreadOpen(request) {
                if let threadOpenError {
                    Banner(text: threadOpenError, symbol: "exclamationmark.triangle.fill") {
                        Button("Retry") {
                            if isCurrentThreadOpen(request) { openThread(request.message) }
                        }
                        Button("Cancel") { if pendingThreadOpen?.id == request.id { cancelThreadOpen() } }
                    }
                } else {
                    Banner(text: "Opening thread…", tone: .neutral) {
                        Button("Cancel") { if pendingThreadOpen?.id == request.id { cancelThreadOpen() } }
                    }.loadingInterval(.threadLoading)
                }
            }
            ErrorBanner(matrix: matrix)
            if let navigationNotice {
                Banner(
                    text: navigationNotice, symbol: "exclamationmark.triangle.fill",
                    onDismiss: { self.navigationNotice = nil })
            }
            if let target = platform.pendingNotification, target.accountID == matrix.user?.id {
                Banner(text: "Opening…", tone: .neutral) {
                    Button("Cancel") { PlatformIntegration.shared.consumeNotification(target) }
                }.loadingInterval(.linkLoading)
            }
            if let localError {
                Banner(text: localError, symbol: "exclamationmark.circle.fill", tone: .destructive) {
                    Button("Retry") {
                        if localAccess == nil { loadLocalData(retry: true) } else { saveLocalData() }
                    }
                }
            }
            if let error = attachmentDrafts.errorMessage {
                Banner(text: error, symbol: "exclamationmark.circle.fill", tone: .destructive) {
                    Button("Retry saving") { retryAttachmentDrafts() }
                }
            }
        }
    }

    @ViewBuilder private func inspector(_ room: ChatRoom?) -> some View {
        if let profilePane {
            ProfilePane(
                matrix: matrix, people: matrix.people, userID: profilePane.id, fallback: profilePane.fallback,
                onOpenConversation: { id in
                    self.profilePane = nil
                    selectRoom(id)
                },
                onEditProfile: { editingProfile = true }, onClose: { self.profilePane = nil })
        } else if let room, let root = threadRoot {
            threadPanel(root: root, room: room)
        } else if let room, let channelPanel {
            listPanel(channelPanel, room: room)
        }
    }

    private func resizeSidebar(_ width: CGFloat) {
        guard width.isFinite else { return }
        let limit = SidebarLayout.effective(
            preferred: SidebarLayout.maximumWidth, availableWidth: widths.available / m.zoom,
            inspectorWidth: occupiedPaneWidth(widths))
        widths.sidebar = min(limit, max(SidebarLayout.minimumWidth, width / m.zoom))
    }
    private func resizePane(_ width: CGFloat) {
        guard width.isFinite else { return }
        widths.pane = min(SidebarLayout.maximumPaneWidth, max(SidebarLayout.minimumPaneWidth, width / m.zoom))
    }
    private func commitPaneWidth() {
        guard widths.pane != nil else { return }
        // Keep what is on screen, not a drag past the limit, so a wider window later does not jump.
        if let shown = paneWidth(widths) { preferredPaneWidth = Double(shown) }
        widths.pane = nil
    }
    private func commitSidebarWidth() {
        guard let width = widths.sidebar else { return }
        preferredSidebarWidth = Double(width)
        widths.sidebar = nil
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
            route: screen.route, workspaceID: workspaceID, visibleBottomRoomID: visibleBottomRoomID,
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

    /// An update waiting, or the preview's one way out: everything else in it is the real interface.
    private var sidebarAccessory: (title: String, action: () -> Void)? {
        if matrix.isPreview {
            return (
                "Sign in",
                {
                    matrix.exitPreview()
                    resetUI()
                }
            )
        }
        return updater.updateAvailable ? ("Update", { updater.checkForUpdates() }) : nil
    }

    /// The conversation list, beside the conversation or in the drawer.
    /// On a frame theme's frame, where it takes the frame's colors, with AppKit's controls drawn dark on a colored one.
    private func sidebar(floating: Bool = false) -> some View {
        Sized(widths, width: sidebarWidth) { sidebarContent(floating: floating) }
            .environment(\.onFrame, colors.theme.framed)
            .transformEnvironment(\.colorScheme) { if colors.theme.framed && !colors.translucentFrame { $0 = .dark } }
    }
    private func sidebarContent(floating: Bool) -> some View {
        SidebarView(
            matrix: matrix,
            route: Binding(
                get: { screen.route == .home && directMessagesColumn ? .directMessages : screen.route },
                set: { next in
                    if next == .directMessages { return openDirectMessages() }
                    directMessagesColumn = false
                    route = next
                }),
            workspaceID: Binding(
                get: { workspaceID },
                set: {
                    Performance.start(.workspaceSwitch)
                    directMessagesColumn = false
                    workspaceID = $0
                    workspaceInitialized = true
                }), directMessageSearch: $directMessageSearch,
            unreadDirectMessagesOnly: $unreadDirectMessagesOnly, draftRoomIDs: draftRoomIDs,
            draftCount: draftAddresses.count,
            onSelect: selectRoom, onCreate: presentCreation,
            onPreferences: { handleMenu("preferences") },
            onProfile: {
                if let me = matrix.user { profilePane = ProfileSelection(id: me.id, fallback: me) }
            },
            onSignOut: { logoutConfirmation = true },
            onMarkUnread: { markReadState($0, unread: true) },
            onMarkRead: { markReadState($0, unread: false) },
            onInviteWorkspace: { id in
                inviteTargetRoomID = id
                creation = .invite
            }, onEditWorkspace: { roomDetails = DetailsSelection(id: $0) },
            onNotifications: { roomNotifications = DetailsSelection(id: $0) },
            onHide: { handleMenu("toggle-sidebar") }, accessory: sidebarAccessory,
            onBrowseChannels: presentPublicDirectory, collapsed: $collapsedSections, floating: floating
        ).layoutIsolated()
    }

    /// The collapsed sidebar, slid over the conversation from the title bar's button, with a scrim that closes it.
    private var drawer: some View {
        let shown = sidebarCollapsed && sidebarDrawer
        return ZStack(alignment: .leading) {
            if shown {
                Button {
                    sidebarDrawer = false
                } label: {
                    colors.scrim.contentShape(Rectangle())
                }.buttonStyle(.row)
                    .focusable(false).accessibilityLabel("Close sidebar").transition(.opacity)
                sidebar(floating: true).padding([.leading, .vertical], m.sidebarInset)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(Motion.pane, value: shown)
    }

    /// The toolbar over the conversation or a page: the sidebar's button while it is folded, back and forward, the
    /// title, the page's own buttons, and search.
    private func toolbar<Title: View, Trailing: View>(
        @ViewBuilder title: () -> Title, @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: m.sp12) {
            if sidebarCollapsed { SidebarToggle(matrix: matrix) { handleMenu("toggle-sidebar") } }
            ToolbarCapsule {
                IconButton(symbol: "chevron.left", label: "Back", role: .body) { navigateHistory(-1) }
                    .disabled(historyIndex <= 0)
                IconButton(symbol: "chevron.right", label: "Forward", role: .body) { navigateHistory(1) }
                    .disabled(historyIndex >= history.count - 1)
            }
            .contextMenu {
                ForEach(Array(history.enumerated()).reversed(), id: \.offset) { index, id in
                    Button(matrix.rooms.first { $0.id == id }?.name ?? "Conversation") {
                        historyIndex = index
                        selectRoom(history[index], record: false)
                    }
                }
            }
            title().frame(maxWidth: .infinity, alignment: .leading).padding(.leading, m.sp4)
            trailing()
            TitleSearch(bar: searchBar, widths: widths, fits: searchFits) {
                SearchBarField(
                    bar: searchBar,
                    prompt: WorkspaceRail.searchPrompt(workspaceID: workspaceID, workspaces: matrix.workspaces),
                    matrix: matrix, recents: recentSearches, visited: history, onPick: pickSearch
                ).frame(width: m(Self.searchWidth))
            }.disabled(matrix.user == nil)
        }
        // The window buttons are AppKit chrome and do not zoom.
        .padding(.leading, sidebarCollapsed ? windowButtonsWidth + m.sp16 : m.sp20).padding(.trailing, m.sp20)
        .frame(height: m.paneHeader).background(WindowDragArea())
        .foregroundStyle(colors.textSecondary)
    }

    private func channelContent(_ room: ChatRoom) -> some View {
        VStack(spacing: 0) {
            if room.membership == "invite" {
                channelHeader(room)
                inviteView(room)
            } else {
                TimelineUnderBars { insets in
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
                        editing: editTarget?.surface == .conversation, onForward: startForward,
                        onEditCaption: startCaption,
                        onOpenMedia: { [viewer] in viewer.open($0, surface: .conversation) },
                        inlineVideo: viewer.inlineVideo, contentAbove: $conversationContentAbove, insets: insets
                    ).id("\(room.id):\(matrix.timelineSelectionID)")
                } header: {
                    channelHeader(room).scrollEdge(.top, colors.canvas)
                } footer: {
                    VStack(spacing: 0) {
                        if room.canPostMessages == false {
                            ComposerNotice(text: Self.cannotPost).padding(.top, m.sp4).padding(.bottom, m.sp12)
                        } else if let target = editTarget, target.surface == .conversation,
                            target.message.roomID == room.id
                        {
                            editComposer(target, room: room).padding(.top, m.sp4).padding(.bottom, m.sp12)
                        } else {
                            BindingScope({ draftBinding(room.id) }) { text in
                                MessageComposer(
                                    text: text,
                                    placeholder: "Message \(room.writtenName)",
                                    members: matrix.members,
                                    recentSenders: { [matrix] in matrix.messages.reversed().map(\.senderID) },
                                    canMentionRoom: matrix.canMentionRoom,
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
                                    onSendText: {
                                        [context = composerContext, reply = scopedReply(roomID: room.id)] body in
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
                            .disabled(!localReady || !attachmentDrafts.ready).id(
                                "composer-\(composerGeneration)-\(room.id)"
                            )
                            .padding(.top, m.sp4).padding(.bottom, m.sp12)
                        }
                    }
                    // Floats above the composer, so a toast, reply or attachment notice never resizes it or moves the
                    // timeline.
                    .overlay(alignment: .top) {
                        VStack(spacing: m.sp8) {
                            ToastHost(toasts: toasts)
                            composerAccessories(
                                reply: replyTarget.flatMap {
                                    $0.message.roomID == room.id
                                        && ($0.threadID == nil || $0.threadID != threadRoot?.eventID) ? $0 : nil
                                },
                                drafts: editTarget == nil ? AttachmentDraftAddress(roomID: room.id) : nil)
                        }.alignmentGuide(.top) { $0[.bottom] }
                    }
                    .frame(maxWidth: m.conversationColumn).frame(maxWidth: .infinity).padding(.horizontal, m.sp12)
                    .scrollEdge(.bottom, colors.canvas)
                }
            }
        }.task(id: room.id + (matrix.user?.id ?? "")) { await loadPinPermission(room) }
            .dropToUpload("Upload to \(room.writtenName)")
    }
    private static let cannotPost = "You don’t have permission to post in this channel."
    private func openChannelPanel(_ panel: ChannelPanel?) {
        if panel != nil {
            if threadRoot != nil { closeThread() }
            profilePane = nil
        }
        channelPanel = panel
    }
    private func channelHeader(_ room: ChatRoom) -> some View {
        toolbar {
            ChannelHeader.Title(matrix: matrix, room: room) { headerAction($0, room: room) }
        } trailing: {
            // In the toolbar, so it never covers or moves a message.
            if matrix.hasLockedMessages {
                Button("Unlock messages") { showRecovery = true }.buttonStyle(.secondary).controlSize(.small)
                    .disabled(matrix.isPreview)
            }
            ChannelHeader(
                matrix: matrix, room: room, panel: Binding(get: { channelPanel }, set: openChannelPanel)
            ) { headerAction($0, room: room) }
        }
    }
    private func headerAction(_ action: ChannelHeader.Action, room: ChatRoom) {
        switch action {
        case .details(let tab): channelDetails = ChannelDetailsSelection(room: room, tab: tab)
        case .profile(let person): openProfile(person.id, fallback: person)
        case .notifications: roomNotifications = DetailsSelection(id: room.id)
        case .star: run { try await matrix.setFavorite(room, value: !room.favorite) }
        case .invite: presentCreation(.invite)
        case .markUnread: markReadState(room, unread: true)
        case .markRead: markReadState(room, unread: false)
        case .copyLink:
            run {
                let link = try await matrix.roomPermalink(room.id)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                toasts.show("Link copied")
            }
        case .search: handleMenu("search-conversation")
        case .leave: leaving = room
        }
    }
    /// Pinned messages or files, beside the conversation as a thread is, so the conversation stays put.
    private func listPanel(_ panel: ChannelPanel, room: ChatRoom) -> some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: panel == .pins ? "Pinned" : "Files", subtitle: room.writtenName,
                closeLabel: panel == .pins ? "Close pinned" : "Close files"
            ) { channelPanel = nil }
            switch panel {
            case .pins:
                PinnedMessagesView(
                    matrix: matrix, service: matrix.pinnedMessages, room: room,
                    onOpen: { message in selectRoom(message.roomID, record: true, eventID: message.eventID) },
                    onOpenProfile: openProfile)
            case .files:
                SharedFilesView(
                    matrix: matrix, service: matrix.sharedFiles, workspaceID: workspaceID, channelID: room.id,
                    onOpen: { selectRoom($0.roomID, record: true, eventID: $0.eventID) },
                    onOpenMedia: { [viewer] in viewer.open($0, files: $1) })
            }
        }.background(colors.canvas)
    }
    private func threadPanel(root: ChatMessage, room: ChatRoom) -> some View {
        TimelineUnderBars { insets in
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
                }, onForward: startForward, onEditCaption: startCaption,
                onOpenMedia: { [viewer] in viewer.open($0, surface: .thread(rootID: root.eventID)) },
                inlineVideo: viewer.inlineVideo, contentAbove: $threadContentAbove, insets: insets
            ).id(root.eventID)
        } header: {
            VStack(spacing: 0) {
                PaneHeader(
                    title: "Thread", subtitle: room.writtenName, closeLabel: "Close thread", onClose: closeThread)
                if let threadLoadError {
                    Banner(text: threadLoadError, symbol: "exclamationmark.triangle.fill") {
                        Button("Retry") { [open = openThreadAction] in open(root) }
                    }
                }
            }.scrollEdge(.top, colors.canvas)
        } footer: {
            VStack(spacing: 0) {
                if room.canPostMessages == false {
                    ComposerNotice(text: Self.cannotPost).padding(.horizontal, m.sp16).padding(.top, m.sp4)
                        .padding(.bottom, m.sp16)
                } else if let target = editTarget, target.surface == .thread(rootID: root.eventID),
                    target.message.roomID == room.id
                {
                    editComposer(target, room: room).padding(.horizontal, m.sp16).padding(.top, m.sp4)
                        .padding(.bottom, m.sp16)
                } else {
                    BindingScope({ threadDraftBinding(root.eventID, roomID: room.id) }) { text in
                        MessageComposer(
                            text: text, placeholder: "Reply…",
                            members: matrix.members,
                            recentSenders: { [matrix] in matrix.threadMessages.reversed().map(\.senderID) },
                            canMentionRoom: matrix.canMentionRoom,
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
                    .id("thread-composer-\(composerGeneration)-\(root.eventID)").padding(.horizontal, m.sp16)
                    .padding(.top, m.sp4)
                    .disabled(
                        !localReady || !attachmentDrafts.ready || threadReadyID != root.eventID
                            || matrix.selectedRoomID != root.roomID)
                    // Only text is copied, so the box sits out a reply with files.
                    let withFiles =
                        attachmentDrafts.queues[
                            AttachmentDraftAddress(roomID: room.id, threadRootID: root.eventID)]?.isEmpty == false
                    Toggle(
                        isOn: Binding(
                            get: { channelCopyRootID == root.eventID && !withFiles },
                            set: { channelCopyRootID = $0 ? root.eventID : nil })
                    ) {
                        if room.isDirect {
                            Text("Also send as direct message")
                        } else {
                            Text(
                                "Also send to \(Image(systemName: room.channelSymbol))\(Text(room.name).fontWeight(.semibold))"
                            )
                        }
                    }.toggleStyle(.checkbox).font(m.font(.body)).foregroundStyle(colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, m.sp16 + m.sp12)
                        .padding(.top, m.sp8).padding(.bottom, m.sp16)
                        .disabled(threadReadyID != root.eventID || withFiles)
                }
            }
            .overlay(alignment: .top) {
                composerAccessories(
                    reply: replyTarget.flatMap { $0.belongsTo(roomID: room.id, threadID: root.eventID) ? $0 : nil },
                    drafts: editTarget == nil
                        ? AttachmentDraftAddress(roomID: room.id, threadRootID: root.eventID) : nil
                ).padding(.horizontal, m.sp12).alignmentGuide(.top) { $0[.bottom] }
            }
            .scrollEdge(.bottom, colors.canvas)
        }.background(colors.canvas).dropToUpload("Upload to thread")
    }
    private var browsedWorkspace: Workspace? { matrix.workspaces.first { $0.id == workspaceID } }
    private func collectionContent(_ route: AppRoute) -> some View {
        VStack(spacing: 0) {
            toolbar {
                if route == .channels {
                    VStack(alignment: .leading, spacing: m(1)) {
                        Text(route.title).font(m.font(.title3, .semibold)).foregroundStyle(colors.textPrimary)
                        Text(browsedWorkspace?.name ?? matrix.homeserverURL.flatMap { URL(string: $0)?.host } ?? "")
                            .font(m.font(.subheadline))
                            .foregroundStyle(colors.textSecondary)
                    }.lineLimit(1)
                } else if route != .search {
                    // Search results title themselves with the query.
                    Text(route.title).font(m.font(.title3, .semibold)).foregroundStyle(colors.textPrimary)
                }
            } trailing: {
                if route == .directory {
                    Button {
                        creation = .directMessage
                    } label: {
                        Label("New message", systemImage: "square.and.pencil")
                    }.buttonStyle(.secondary)
                }
            }
            switch route {
            case .channels:
                PublicRoomDirectoryView(
                    matrix: matrix, service: matrix.publicDirectory, workspace: browsedWorkspace,
                    onResolve: openBrowsedChannel
                ).id(workspaceID)
            case .directory: PeopleDirectoryView(matrix: matrix, people: matrix.people, onOpenProfile: openProfile)
            case .threads:
                ThreadsFeedView(
                    matrix: matrix, feed: matrix.threadFeed, workspaceID: $workspaceID, onOpen: openThreadAction)
            case .files:
                SharedFilesView(
                    matrix: matrix, service: matrix.sharedFiles, workspaceID: workspaceID,
                    onOpen: { selectRoom($0.roomID, record: true, eventID: $0.eventID) },
                    onOpenMedia: { [viewer] in viewer.open($0, files: $1) })
            case .saved: savedCollection
            case .drafts: draftsCollection
            case .activity:
                ActivityFeedView(
                    matrix: matrix, activity: matrix.activity, workspaceID: $workspaceID, onOpenMessage: openActivity,
                    onOpenRoom: selectRoom)
            case .search:
                SearchResultsView(
                    matrix: matrix, bar: searchBar,
                    onOpenMessage: { selectRoom($0.roomID, record: true, eventID: $0.eventID) },
                    onOpenRoom: selectRoom, onOpenProfile: openProfile)
            case .home, .directMessages: EmptyView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { ToastHost(toasts: toasts).padding(.bottom, m.sp24) }
    }
    private var savedCollection: some View {
        SavedMessagesView(
            matrix: matrix, list: matrix.savedMessages.list,
            actions: LaterActions(
                open: { item in selectRoom(item.roomID, record: true, eventID: item.eventID) },
                move: { item, state in
                    matrix.savedMessages.set(roomID: item.roomID, eventID: item.eventID, state: state)
                    toasts.show(state.moved)
                },
                remind: { item, date in
                    matrix.savedMessages.remind(roomID: item.roomID, eventID: item.eventID, at: date)
                },
                remove: { item in
                    matrix.savedMessages.set(roomID: item.roomID, eventID: item.eventID, saved: false)
                    toasts.show("Removed from Later")
                })
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
        let draft =
            address.threadRootID.map {
                drafts.threads[ThreadDraftAddress(roomID: address.roomID, rootID: $0).id] ?? ""
            } ?? drafts.conversations[address.roomID] ?? ""
        let text = ComposerFormat.message(draft: draft).body
        let count = max(attachmentDrafts.queues[address]?.count ?? 0, attachmentDrafts.files[address]?.count ?? 0)
        return text + (count == 0 ? "" : (text.isEmpty ? "" : "\n") + "\(count) attachment\(count == 1 ? "" : "s")")
    }
    @ViewBuilder private func attachmentDraftStatus(_ address: AttachmentDraftAddress) -> some View {
        if !attachmentDrafts.ready {
            HStack(spacing: m.sp8) {
                DelayedProgress()
                Text("Restoring attachments…")
                Spacer()
            }.font(m.font(.subheadline)).foregroundStyle(colors.textSecondary).padding(m.sp12).modifier(
                ComposerCard(colors: colors)
            )
            .loadingInterval(.attachmentsLoading)
        }
        if localReady && attachmentDrafts.needsReview(address) {
            HStack(alignment: .top, spacing: m.sp8) {
                Image(systemName: "exclamationmark.triangle")
                Text("Upload interrupted; it may have sent.")
                Spacer()
                Button("Send anyway") { attachmentDrafts.allowResend(address) }.buttonStyle(.textLink)
            }.font(m.font(.subheadline)).padding(m.sp12).modifier(ComposerCard(colors: colors))
        }
        ForEach(localReady ? attachmentDrafts.files[address, default: []].filter { $0.url == nil } : []) { file in
            HStack(alignment: .top, spacing: m.sp8) {
                Image(systemName: "doc.badge.exclamationmark")
                VStack(alignment: .leading, spacing: m.sp4) {
                    Text(file.filename).fontWeight(.medium)
                    Text(file.errorMessage ?? "Saved attachment unavailable")
                }
                Spacer()
                Button("Remove") { attachmentDrafts.removeUnavailable(file, at: address) }.buttonStyle(.textLink)
            }.font(m.font(.subheadline)).padding(m.sp12).modifier(ComposerCard(colors: colors))
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
                    colors.textSecondary)
                RoomName(matrix: matrix, roomID: roomID).font(m.font(.reading, .semibold))
                if thread { Text("Thread reply").font(m.font(.subheadline)).foregroundStyle(colors.textSecondary) }
                Spacer()
                Image(systemName: "chevron.right").font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
            }
            Text(body).font(m.font(.body)).foregroundStyle(colors.textSecondary).lineLimit(3)
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
        DelayedProgress(interval: .conversationLoading).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button("Decline") { respondToInvitation(room, accepting: false) }.buttonStyle(.secondary)
                Button(room.isSpace ? "Join workspace" : "Join") { respondToInvitation(room, accepting: true) }
                    .buttonStyle(.primary)
            }.disabled(busy || matrix.isPreview)
            // Reserved, so the buttons never move when the spinner comes and goes.
            DelayedProgress().opacity(busy ? 1 : 0)
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
                Rectangle().fill(colors.accent).frame(width: m(3), height: m.control)
                VStack(alignment: .leading, spacing: m.sp4) {
                    Text("Replying to \(target.message.senderName)\(target.threadID == nil ? "" : " in thread")").font(
                        m.font(.subheadline, .semibold))
                    NativeMessageBody(
                        body: target.message.body, formattedBody: target.message.formattedBody,
                        showsSpoilerControl: false
                    ).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Cancel reply", role: .subheadline) {
                    guard target.isCurrent(replyTarget, owner: replyOwner) else { return }
                    cancelReply()
                }
            }.overlay(alignment: .trailing) {
                DelayedProgress(
                    active: replyOpening, offline: matrix.connectionState == .offline, interval: .replyLoading
                ).padding(.trailing, m.iconButton + m.sp8)
            }
            if !replyOpening, let replyError {
                HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                    Text(replyError).foregroundStyle(colors.textSecondary)
                    Button("Retry") { prepareReply(target) }.buttonStyle(.textLink)
                }.font(m.font(.subheadline))
            }
        }.padding(.horizontal, m.sp16).padding(.vertical, m.sp8).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ComposerCard(colors: colors))
    }
    private func composerAccessories(reply: MessageReplyTarget?, drafts: AttachmentDraftAddress?) -> some View {
        VStack(alignment: .leading, spacing: m.sp4) {
            if let reply { replyBanner(reply) }
            if let drafts { attachmentDraftStatus(drafts) }
        }.padding(.bottom, m.sp4)
    }
    private func startReply(_ message: ChatMessage, surface: MessageReplyTarget.Surface, session: UUID, timeline: UUID)
    {
        guard !matrix.isPreview, localReady, pendingRoomID == nil, route == .home,
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
            route == .home, room?.id == target.message.roomID, room?.membership == "join"
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
                    && room?.id == target.message.roomID && room?.membership == "join"
            }
            guard isCurrent() else { return }
            do {
                var root: ChatMessage?
                if let rootID = target.threadID {
                    root = try await ThreadRootResolver.resolve(
                        roomID: target.message.roomID, rootID: rootID,
                        candidates: matrix.messages + matrix.threadMessages + matrix.threadFeed.roots,
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

    /// Slack's DMs view: the list takes the sidebar column, beside the direct message read last, or the newest.
    private func openDirectMessages() {
        directMessagesColumn = true
        route = .home
        guard room?.isDirect != true else { return }
        guard let id = ChatRoom.directMessageToOpen(matrix.rooms, visited: Array(history.prefix(historyIndex + 1)))
        else { return }
        // Picked in the drawer, the list stays open there.
        let drawer = sidebarDrawer
        selectRoom(id)
        sidebarDrawer = drawer
    }
    private func selectRoom(
        _ id: String, record: Bool, eventID: String? = nil, thread: ChatMessage? = nil,
        keepPendingNotification: Bool = false, restoringReply: MessageReplyTarget? = nil
    ) {
        sidebarDrawer = false
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
        if let current = matrix.selectedRoomID, current != id, let open = threadRoot { leftThreads[current] = open }
        // Only a plain visit: a jump to a message or a thread of its own wins.
        let leftThread = thread == nil && eventID == nil && restoringReply == nil ? leftThreads[id] : nil
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
        pickedFrom = screen
        pendingRoomID = id
        if let target = matrix.rooms.first(where: { $0.id == id }) {
            if !target.isDirect { directMessagesColumn = false }
            if !target.isDirect, let current = workspaceID, !target.spaceIDs.contains(current) {
                workspaceID = WorkspaceRail.home(of: target, current: current, workspaces: matrix.workspaces)
                workspaceInitialized = true
            }
        } else {
            workspaceID = nil
            workspaceInitialized = true
        }
        route = .home
        if id != matrix.selectedRoomID { channelPanel = nil }
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
            if let thread = thread ?? leftThread {
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
                    guard restoringReply.isCurrent(replyTarget, owner: replyOwner), route == .home, room?.id == id
                    else {
                        pendingRoomID = nil
                        return
                    }
                }
                var replyRootID: String?
                if let resumeAnchor, eventID == nil {
                    await matrix.resumeRoom(id, at: resumeAnchor)
                } else if let destinationEventID {
                    replyRootID = await matrix.jumpToMessage(roomID: id, eventID: destinationEventID)
                } else if thread == nil || requiresRoomSelection {
                    await matrix.selectRoom(id)
                }
                guard navigationGeneration == generation, composerIdentity == identity, matrix.selectedRoomID == id
                else { return }
                pendingRoomID = nil
                if let restoringReply {
                    guard restoringReply.isCurrent(replyTarget, owner: replyOwner), route == .home, room?.id == id
                    else { return }
                    guard matrix.isLiveTimelineReady(roomID: id) else {
                        replyOpening = false
                        replyError = "Couldn’t load recent messages. Try again."
                        return
                    }
                }
                // A jump to a thread reply opens its thread beside the conversation, as Slack does.
                let replyRoot = replyRootID.flatMap { root in matrix.messages.first { $0.eventID == root } }
                if let thread = thread ?? replyRoot ?? leftThread {
                    await loadThread(thread, generation: generation, identity: identity, restoringReply: restoringReply)
                } else if let restoringReply, restoringReply.isCurrent(replyTarget, owner: replyOwner) {
                    replyOpening = false
                    replyError = nil
                }
            }
        }
    }
    /// A thread in the conversation on screen opens beside it, which stays as it is; one elsewhere opens with its
    /// conversation.
    private func openThread(_ root: ChatMessage, room id: String) {
        matrix.activity.markThreadOpened(roomID: id, rootID: root.eventID)
        guard id == matrix.selectedRoomID, pendingRoomID == nil, route == .home,
            matrix.isPreview || matrix.isLiveTimelineReady(roomID: id)
        else { return selectRoom(id, record: true, thread: root) }
        let generation = UUID()
        navigationGeneration = generation
        matrix.setMessageActionThread(rootID: nil)
        threadReadyID = nil
        threadLoadError = nil
        if matrix.isPreview {
            threadRoot = root
            matrix.openPreviewThread(root)
            threadReadyID = root.eventID
            return
        }
        let identity = composerIdentity
        Task { @MainActor in await loadThread(root, generation: generation, identity: identity, restoringReply: nil) }
    }
    private func loadThread(
        _ thread: ChatMessage, generation: UUID, identity: ComposerIdentity, restoringReply: MessageReplyTarget?
    ) async {
        let id = thread.roomID
        threadRoot = thread
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
            guard navigationGeneration == generation, composerIdentity == identity, matrix.selectedRoomID == id
            else { return }
            openingThreadID = nil
            if let restoringReply, restoringReply.isCurrent(replyTarget, owner: replyOwner) {
                replyOpening = false
                replyError = MatrixService.safeError(error)
            } else {
                threadLoadError = MatrixService.safeError(error)
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
        let candidates = [message] + matrix.messages + matrix.threadMessages + matrix.threadFeed.roots
        if matrix.isPreview {
            guard let root = candidates.first(where: { $0.eventID == rootID && $0.roomID == message.roomID }) else {
                return
            }
            openThread(root, room: root.roomID)
            return
        }
        Performance.start(.threadOpen)
        cancelThreadOpen()
        cancelReply()
        navigationGeneration = UUID()
        let request = ThreadOpenRequest(
            message: message, owner: composerIdentity,
            selection: matrix.timelineSelectionID, navigation: navigationGeneration,
            workspace: workspaceID, sourceRoute: route,
            selectedRoomID: matrix.selectedRoomID)
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
                openThread(root, room: root.roomID)
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
            && request.workspace == workspaceID
            && route == request.sourceRoute && pendingRoomID == nil && localReady
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
        // A mention opens its person's profile, as a click on a sender's name does.
        if case .user(let userID)? = (try? MatrixLinkService.parse(url))?.id {
            openProfile(userID, fallback: nil)
            return .handled
        }
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
        guard !hasModal, !hasNativeModal, !matrix.verification.isPresented else { return }
        cancelMatrixLink()
        route = .channels
    }
    /// A channel picked in Browse channels opens like a link to it: straight in when joined, else its join review.
    private func openBrowsedChannel(_ resolution: MatrixLinkResolution) {
        guard let accountID = matrix.user?.id, resolution.accountID == accountID,
            resolution.sessionID == matrix.notificationSessionID, route == .channels
        else { return }
        cancelMatrixLink()
        pendingMatrixLink = PendingMatrixLink(
            source: .resolved(resolution), accountID: accountID, session: matrix.notificationSessionID,
            navigation: navigationGeneration, route: route, workspaceID: workspaceID)
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
        if let rootID = item.threadRootID { matrix.activity.markThreadOpened(roomID: item.roomID, rootID: rootID) }
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
            !matrix.isPreview, localReady, pendingRoomID == nil, route == .home,
            room?.id == target.message.roomID, room?.membership == "join",
            matrix.isCurrentMessageAction(target)
        else { return }
        forwarding = ForwardSelection(target: target, navigation: navigationGeneration, workspaceID: workspaceID)
    }
    private func cancelStaleForward() {
        guard let selection = forwarding else { return }
        guard selection.navigation == navigationGeneration, selection.workspaceID == workspaceID,
            route == .home, pendingRoomID == nil,
            room?.id == selection.target.message.roomID, room?.membership == "join",
            matrix.isCurrentMessageAction(selection.target)
        else {
            forwarding = nil
            return
        }
    }
    private func startCaption(_ target: MessageActionTarget) {
        guard !hasModal, !hasNativeModal, !matrix.verification.isPresented,
            !matrix.isPreview, localReady, pendingRoomID == nil, route == .home,
            room?.id == target.message.roomID, room?.membership == "join",
            matrix.isCurrentMessageAction(target)
        else { return }
        mediaCaption = CaptionSelection(target: target, navigation: navigationGeneration, workspaceID: workspaceID)
    }
    private func cancelStaleCaption() {
        guard let selection = mediaCaption else { return }
        guard selection.navigation == navigationGeneration, selection.workspaceID == workspaceID,
            route == .home, pendingRoomID == nil,
            room?.id == selection.target.message.roomID, room?.membership == "join",
            matrix.isCurrentMessageAction(selection.target)
        else {
            mediaCaption = nil
            return
        }
    }
    private func startEdit(_ action: MessageActionTarget) {
        let message = action.message
        guard !matrix.isPreview, localReady, pendingRoomID == nil, route == .home,
            room?.id == message.roomID, room?.membership == "join", matrix.isCurrentMessageAction(action),
            let target = MessageEditTarget(message: message, surface: action.surface, context: editContext)
        else { return }
        editTarget = target
        editActionTarget = action
        editText = ComposerFormat.draft(body: message.body, html: message.formattedBody)
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
        return isCurrentComposer(context) && pendingRoomID == nil && route == .home
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
        try await sendText(body, room: room, threadID: threadID, context: context, reply: reply, copies: files.isEmpty)
        for file in files { try await sendFile(file, room: room, threadID: threadID, context: context) }
    }
    /// `copies` lets a checked "Also send to #channel" copy the text, which it can't for a reply with files.
    private func sendText(
        _ body: String, room: ChatRoom, threadID: String? = nil, context: ComposerContext, reply: MessageReplyTarget?,
        copies: Bool = true
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
                || (route == .home && room.id == self.room?.id
                    && matrix.isLiveTimelineReady(roomID: room.id) && !replyOpening && replyError == nil
                    && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        else {
            throw MatrixServiceError.request("The reply changed. Check it and send again.")
        }
        let alsoToChannel = copies && threadID != nil && threadID == channelCopyRootID
        try await matrix.sendMessage(
            body, threadRootID: threadID, replyToID: reply?.message.eventID, roomID: room.id,
            alsoToChannel: alsoToChannel)
        // Slack unchecks "Also send to #channel" once a reply goes.
        if threadID != nil, isCurrentComposer(context), channelCopyRootID == threadID { channelCopyRootID = nil }
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
    /// Slack's profile in the side pane, starting from the name and photo the room already knows.
    private func openProfile(_ userID: String, fallback: ChatUser?) {
        guard matrix.user != nil else { return }
        profilePane = ProfileSelection(id: userID, fallback: fallback ?? matrix.members.first { $0.id == userID })
    }
    private func toggleSave(_ message: ChatMessage) {
        guard localReady else { return }
        guard matrix.isPreview || message.eventID.hasPrefix("$") else {
            matrix.errorMessage = "Wait for the message to send, then save it."
            return
        }
        let save = !savedIDs.contains(SavedMessageReference(roomID: message.roomID, eventID: message.eventID).id)
        matrix.savedMessages.set(roomID: message.roomID, eventID: message.eventID, saved: save)
        toasts.show(save ? "Message saved for later" : "Removed from Later")
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
        guard matrix.roomsLoaded else { return }
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
        ProtectedLocalState(
            drafts: drafts.conversations, threadDrafts: drafts.threads, saved: matrix.savedMessages.list.saved,
            recentSearches: recentSearches, savedRemovals: matrix.savedMessages.list.removed)
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
                matrix.savedMessages.merge(
                    SavedMessages(saved: access.state.saved, removed: access.state.savedRemovals ?? []),
                    accountID: accountID)
                recentSearches = access.state.recentSearches ?? []
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
        recentSearches = []
        searchBar.text = ""
        searchBar.submitted = nil
        searchBar.close()
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
        viewer.close()
        viewer.inlineVideo.stop()
        clearComposerState()
        workspaceID = nil
        workspaceInitialized = false
        channelDetails = nil
        leaving = nil
        channelPanel = nil
        pinPermissionRoomID = nil
        pinPermission = false
        route = .home
        history = []
        historyIndex = -1
        directMessagesColumn = false
        directMessageSearch = ""
        unreadDirectMessagesOnly = false
        modals.current = nil
        showRecovery = false
        creation = nil
        inviteTargetRoomID = nil
        popovers.close()
        profilePane = nil
        roomDetails = nil
        roomNotifications = nil
        leftThreads = [:]
        loadLocalData()
    }
    private func closeThread() {
        if let id = matrix.selectedRoomID { leftThreads[id] = nil }
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
        // Esc closes the profile first, then marks read.
        case .markRead: if profilePane != nil { profilePane = nil } else { markReadState(room, unread: false) }
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
    private func pickSearch(_ item: SearchSuggestion) {
        searchBar.close()
        switch item {
        case .search(let text), .recent(let text):
            searchBar.text = text
            recentSearches = RecentSearches.adding(text, to: recentSearches)
            saveLocalData()
            searchBar.submitted = MessageSearchQuery.parse(text, rooms: matrix.rooms, me: matrix.user?.id)
            route = .search
        case .conversation(let room):
            searchBar.text = ""
            selectRoom(room.id)
        }
    }
    private func handleMenu(_ action: String) {
        // The media viewer covers the window: Esc closes it, and nothing else reaches what is under it.
        if viewer.message != nil {
            if action == "mark-read" { viewer.close() }
            return
        }
        // Esc reaches here when nothing in the modal took it: it closes the modal, as in Slack.
        if modals.current != nil, action == "mark-read" { return closeModal() }
        guard !hasModal, !hasNativeModal, !matrix.verification.isPresented else { return }
        if action == "shortcuts" {
            modals.current = .shortcuts
            return
        }
        if action == "preferences" {
            Performance.start(.preferencesOpen)
            modals.current = .preferences(.appearance)
            return
        }
        guard matrix.user != nil else { return }
        if action == "search" { Performance.start(.searchOpen) }
        switch action {
        case "search": modals.current = .switcher
        case "search-messages": searchBar.focus()
        case "search-conversation":
            // Slack's ⌘F: the bar, already narrowed to the open conversation.
            let name = room.map { $0.name.contains(" ") ? "\"\($0.name)\"" : ($0.isDirect ? "@" : "#") + $0.name }
            searchBar.focus(text: route == .home ? name.map { "in:\($0) " } : nil)
        case "new-message": creation = .directMessage
        case "new-channel": creation = .channel
        case "back": navigateHistory(-1)
        case "forward": navigateHistory(1)
        case "threads": route = .threads
        case "dms": openDirectMessages()
        case "activity": route = .activity
        case "later": route = .saved
        case "people": route = .directory
        case "files": route = .files
        case "browse-channels": presentPublicDirectory()
        case _ where action.hasPrefix("workspace-"):
            let rail = WorkspaceRail.entries(workspaces: matrix.workspaces, rooms: matrix.rooms)
            guard let index = Int(action.dropFirst("workspace-".count)), rail.indices.contains(index - 1) else {
                return
            }
            Performance.start(.workspaceSwitch)
            directMessagesColumn = false
            workspaceID = rail[index - 1]?.id
            workspaceInitialized = true
            route = .home
        case "toggle-sidebar":
            // A window too narrow for the sidebar can only show it as the drawer.
            if !(paneOpen ? arrangement.sidebarFitsBesidePane : arrangement.sidebarFits) {
                sidebarDrawer.toggle()
            } else {
                sidebarHidden.toggle()
                sidebarDrawer = false
            }
        case "toggle-pane":
            if profilePane != nil {
                profilePane = nil
                return
            }
            if route == .home, threadRoot != nil { closeThread() }
            channelPanel = nil
        case "mark-read":
            if sidebarCollapsed && sidebarDrawer {
                sidebarDrawer = false
            } else if profilePane != nil {
                profilePane = nil
            } else if route == .home, let room {
                _ = conversationKey(.markRead, room: room, threadRootID: nil)
            }
        case "mark-all-read":
            for room in matrix.rooms where room.membership == "join" && room.hasUnread {
                markReadState(room, unread: false)
            }
        case "react-last":
            guard route == .home, editTarget == nil,
                let last = matrix.messages.last(where: { $0.sendState == "sent" && !$0.isRedacted }),
                let target = matrix.captureMessageAction(message: last, surface: .conversation)
            else { return }
            popovers.show(.emoji(EmojiPick { key in run { try await matrix.toggleReaction(target, key: key) } }))
        case "previous-conversation", "next-conversation", "previous-unread", "next-unread":
            let direction = action.hasPrefix("previous") ? -1 : 1
            let currentID = pendingRoomID ?? matrix.selectedRoomID
            let unreadOnly = action.hasSuffix("unread")
            let target: String?
            if route == .home && directMessagesColumn {
                // Through the DMs list, as the sidebar column shows it.
                let shown = ChatRoom.directMessages(
                    matrix.rooms, matching: directMessageSearch, unreadOnly: unreadDirectMessagesOnly,
                    keeping: matrix.selectedRoomID)
                target = ConversationNavigation.step(
                    shown, from: currentID, unreadOnly: unreadOnly, direction: direction)
            } else {
                target = ConversationNavigation.target(
                    rooms: matrix.rooms, currentID: currentID, workspaceID: workspaceID, unreadOnly: unreadOnly,
                    direction: direction)
            }
            if let target { selectRoom(target) }
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
            isMainTimeline: route == .home,
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

/// The title bar's button for the collapsed sidebar. Reads the room list itself, so unread changes redraw only it.
private struct SidebarShownKey: FocusedValueKey { typealias Value = Bool }
private struct RightPaneShownKey: FocusedValueKey { typealias Value = Bool }

extension FocusedValues {
    /// Whether the window shows its sidebar, inline or as the drawer, for the View menu's Show or Hide Sidebar.
    var sidebarShown: Bool? {
        get { self[SidebarShownKey.self] }
        set { self[SidebarShownKey.self] = newValue }
    }
    /// Whether a thread, list or profile shows beside the conversation, for the View menu's Hide Right Pane.
    var rightPaneShown: Bool? {
        get { self[RightPaneShownKey.self] }
        set { self[RightPaneShownKey.self] = newValue }
    }
}

private struct SidebarToggle: View {
    let matrix: MatrixService
    let action: () -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        let badge = UnreadBadge.combined(matrix.rooms)
        let colors = appearance.colors
        ToolbarCapsule {
            IconButton(symbol: "sidebar.left", label: "Show sidebar", role: .body, action: action)
        }
        // A count for mentions and direct messages, a dot for the rest.
        .overlay(alignment: .topTrailing) {
            switch badge {
            case .count(let count):
                CountBadge(text: count, small: true).overlay(Capsule().stroke(colors.canvas, lineWidth: m.sp2))
                    .offset(x: m(6), y: -m.sp4)
            case .bold:
                Circle().fill(colors.accentFill).frame(width: m(8), height: m(8))
                    .overlay(Circle().stroke(colors.canvas, lineWidth: m.sp2)).offset(x: m.sp2, y: -m.sp2)
            case .none: EmptyView()
            }
        }
        .accessibilityValue(
            {
                switch badge {
                case .count(let count): "\(count) unread"
                case .bold: "Unread messages"
                case .none: ""
                }
            }())
    }
}

/// The title bar's search field, or in a narrow window a button that opens it in its place until it closes.
private struct TitleSearch<Field: View>: View {
    let bar: SearchBar
    let widths: PaneWidths
    let fits: (PaneWidths) -> Bool
    @ViewBuilder let field: () -> Field
    @State private var open = false
    var body: some View {
        let fits = fits(widths)
        return Group {
            if fits || open {
                // Opened from the button, ⌘G or ⌘F: the field was not there to take the cursor, so it takes it now.
                field().onAppear { if open { bar.focus() } }
            } else {
                IconButton(symbol: "magnifyingglass", label: "Search", role: .body) { open = true }
            }
        }
        .onChange(of: bar.focusRequests) { _, _ in if !fits { open = true } }
        .onChange(of: bar.menuOpen) { _, menuOpen in if !menuOpen { open = false } }
    }
}

/// A lost connection, once it has lasted a moment. On its own, so connection changes redraw only the banner.
private struct ConnectionBanner: View {
    let matrix: MatrixService
    let onRetry: () -> Void
    @State private var shown = false
    var body: some View {
        let message = matrix.connectionErrorMessage
        ZStack {
            if shown, let message {
                // While a retry runs the notice itself says so, so the button steps aside.
                Banner(
                    text: message,
                    symbol: matrix.connectionSymbol
                ) {
                    if matrix.canRetryConnection { Button("Retry", action: onRetry) }
                }.transition(.opacity)
            }
        }
        .animation(Motion.overlay, value: shown)
        .task(id: message != nil) {
            shown = false
            guard message != nil else { return }
            let start = ContinuousClock.now
            try? await Task.sleep(for: LoadingPresentation.connectionNoticeDelay)
            guard !Task.isCancelled else { return }
            shown = LoadingPresentation.showsConnectionNotice(downFor: .now - start)
        }
    }
}

private struct ErrorBanner: View {
    let matrix: MatrixService
    var body: some View {
        if let error = matrix.errorMessage {
            Banner(
                text: error, symbol: "exclamationmark.triangle.fill", onDismiss: { matrix.errorMessage = nil })
        }
    }
}

/// Who is typing in the open conversation, on a line of its own so typing redraws nothing else.
private struct RoomName: View {
    let matrix: MatrixService
    let roomID: String
    var body: some View { Text(matrix.rooms.first { $0.id == roomID }?.name ?? "Conversation") }
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

/// Closes the media viewer once its message leaves what is shown; on its own, so new messages do not redraw the
/// window.
private struct ViewerInvalidation: View {
    let matrix: MatrixService
    let viewer: MediaViewerState
    var body: some View {
        Color.clear
            .onChange(of: matrix.messages) {
                if viewer.files == nil && viewer.surface == .conversation { viewer.update(from: matrix.messages) }
            }
            .onChange(of: matrix.threadMessages) {
                if viewer.files == nil && viewer.surface != .conversation { viewer.update(from: matrix.threadMessages) }
            }
            .onChange(of: matrix.sharedFiles.items) {
                if viewer.files != nil { viewer.update(from: matrix.sharedFiles.items.map(\.message)) }
            }
    }
}

/// What lies outside a rounded rectangle within its square bounds: its four corners.
private struct OutsideCorners: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addPath(RoundedRectangle(cornerRadius: radius).path(in: rect))
        return path
    }
}

/// A card floating above the composer: it never moves what is under it.
private struct ComposerCard: ViewModifier {
    @Environment(\.metrics) private var m
    let colors: AppColors
    func body(content: Content) -> some View {
        content.background(colors.raised).clipShape(RoundedRectangle(cornerRadius: m.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
            .elevation(.e2, cornerRadius: m.radiusLarge)
    }
}

/// The widths that change with every step of a resize: the window's, and a divider's while it is dragged, at 100%
/// zoom. Only the frames and controls that need a width read them, so a step lays the window out without building
/// it again.
@Observable final class PaneWidths {
    var available: CGFloat = 1_440
    var sidebar: CGFloat?
    var pane: CGFloat?
}

/// `content`, built once by its parent, as wide as `width` makes it.
private struct Sized<Content: View>: View {
    let widths: PaneWidths
    let width: (PaneWidths) -> CGFloat
    let content: Content
    init(_ widths: PaneWidths, width: @escaping (PaneWidths) -> CGFloat, @ViewBuilder content: () -> Content) {
        self.widths = widths
        self.width = width
        self.content = content()
    }
    var body: some View { content.frame(width: width(widths)) }
}

/// Builds `content` from the widths, so only it redraws as they change.
private struct WithWidths<Content: View>: View {
    let widths: PaneWidths
    @ViewBuilder let content: (PaneWidths) -> Content
    init(_ widths: PaneWidths, @ViewBuilder content: @escaping (PaneWidths) -> Content) {
        self.widths = widths
        self.content = content
    }
    var body: some View { content(widths) }
}
