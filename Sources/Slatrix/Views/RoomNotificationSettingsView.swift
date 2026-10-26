import SwiftUI

struct RoomNotificationSettingsView: View {
    private static let size = CGSize(width: 532, height: 492)
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    private var retries: NotificationSettingsRetryState { matrix.notificationRetries }
    let roomID: String
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var owner: Context?
    @State private var snapshot: RoomNotificationSnapshot?
    @State private var choice = RoomNotificationChoice.accountDefault
    @State private var loading = false
    @State private var saving = false
    @State private var retryingFailedUpdate = false
    @State private var failedRequestedChoice: RoomNotificationChoice?
    @State private var needsReload = false
    @State private var error: String?
    @State private var notice: String?
    @State private var request = UUID()
    @State private var handledRevision = -1

    init(matrix: MatrixService, roomID: String, onClose: @escaping () -> Void) {
        self.matrix = matrix
        self.roomID = roomID
        self.onClose = onClose
    }

    private struct Context: Hashable {
        let roomID: String
        let session: UUID
        let userID: String?
        let preview: Bool
    }
    private var context: Context {
        Context(
            roomID: roomID, session: matrix.notificationSessionID, userID: matrix.user?.id, preview: matrix.isPreview)
    }
    private var current: Bool { owner == context && context.userID != nil && !context.preview }
    private var colors: AppColors { appearance.colors }
    private var name: String { matrix.rooms.first { $0.id == roomID }?.name ?? roomID }
    private var canSave: Bool {
        current && !loading && !saving && !retries.isWriting && !needsReload && snapshot != nil
            && (retryingFailedUpdate || snapshot?.choice != choice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: m.sp16) {
                VStack(alignment: .leading, spacing: m.sp8) {
                    Text("Notifications").font(m.font(.header, .bold)).foregroundStyle(
                        colors.textPrimary)
                    Text(name).font(m.font(.secondary)).lineLimit(2)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Close", role: .secondary, action: onClose)
                    .disabled(
                        saving)
            }.padding(m.sp24)
            Divider().overlay(colors.border)
            ScrollView {
                VStack(alignment: .leading, spacing: m.sp20) {
                    if loading {
                        HStack(spacing: m.sp8) {
                            DelayedProgress(interval: .sheetLoading)
                            Text("Loading…").font(m.font(.secondary)).foregroundStyle(
                                colors.textSecondary)
                        }.padding(.vertical, m.sp20)
                    } else if let snapshot, current {
                        Picker("Notify me about", selection: $choice) {
                            ForEach(RoomNotificationChoice.allCases) { option in
                                Text(
                                    option == .accountDefault
                                        ? "Default (\(snapshot.defaultChoice.title))" : option.title
                                ).tag(option)
                            }
                        }.pickerStyle(.radioGroup).font(m.font(.secondary)).disabled(
                            saving || retries.isWriting || needsReload)

                    }
                    if let notice {
                        Label(notice, systemImage: "info.circle").font(m.font(.meta)).foregroundStyle(
                            colors.textSecondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error {
                        Text(error).font(m.font(.meta)).foregroundStyle(colors.destructive).fixedSize(
                            horizontal: false, vertical: true
                        ).textSelection(.enabled)
                    }
                    if retries.isWriting && !saving {
                        HStack(spacing: m.sp8) {
                            DelayedProgress()
                            Text("Saving…")
                        }.font(m.font(.meta))
                    }
                    if current && !loading && !saving && !retries.isWriting {
                        Button(snapshot == nil ? "Try again" : "Reload") { Task { await load() } }
                            .buttonStyle(.textLink).font(m.font(.meta))
                    }
                }.padding(m.sp24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(colors.border)
            HStack(spacing: m.sp12) {
                if saving {
                    DelayedProgress()
                    Text("Saving…").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction).disabled(saving)
                Button(retryingFailedUpdate ? "Retry update" : "Save changes", action: save)
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(
                        !canSave)
            }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16)
        }.sheetSize(width: Self.size.width, height: Self.size.height).background(colors.canvas).foregroundStyle(
            colors.textBody
        )
        .task(id: context) {
            if owner == nil { owner = context }
            guard current else {
                request = UUID()
                snapshot = nil
                loading = false
                saving = false
                choice = .accountDefault
                failedRequestedChoice = nil
                retryingFailedUpdate = false
                notice = nil
                error = "Something changed. Open these settings again."
                return
            }
            await load()
        }
        .onChange(of: retries.revision) { _, _ in
            Task { @MainActor in
                guard current, !saving, !retries.isWriting, handledRevision != retries.revision else { return }
                await load()
            }
        }
        .onDisappear { request = UUID() }
    }

    @MainActor private func load() async {
        guard current, !saving, !retries.isWriting else { return }
        let identity = context
        let token = UUID()
        let revision = retries.revision
        request = token
        loading = true
        error = nil
        notice = nil
        do {
            let loaded = try await matrix.loadRoomNotificationSettings(roomID: identity.roomID)
            guard !Task.isCancelled, current, context == identity, request == token, loaded.roomID == identity.roomID
            else { return }
            guard retries.revision == revision, !retries.isWriting else {
                refreshAfterOwnerChange()
                return
            }
            handledRevision = revision
            failedRequestedChoice = loaded.pendingRetryChoice
            snapshot = loaded
            choice = loaded.pendingRetryChoice ?? loaded.choice
            loading = false
            needsReload = false
            retryingFailedUpdate = failedRequestedChoice != nil
            if retryingFailedUpdate {
                notice =
                    "Saving was interrupted. Choose Retry to finish."
            }
        } catch {
            guard !Task.isCancelled, current, context == identity, request == token else { return }
            guard retries.revision == revision, !retries.isWriting else {
                refreshAfterOwnerChange()
                return
            }
            handledRevision = revision
            loading = false
            needsReload = true
            self.error = MatrixService.safeError(error)
        }
    }

    @MainActor private func refreshAfterOwnerChange() {
        loading = false
        needsReload = true
        if !retries.isWriting { Task { await load() } }
    }

    @MainActor private func save() {
        guard canSave else { return }
        let identity = context
        let token = UUID()
        let requested = choice
        request = token
        saving = true
        error = nil
        notice = nil
        Task { @MainActor in
            do {
                guard current, context == identity, request == token else { return }
                handledRevision = retries.revision
                let result = try await matrix.saveRoomNotificationSettings(roomID: identity.roomID, choice: requested)
                guard current, context == identity, request == token else { return }
                handledRevision = retries.revision
                if let observed = result.snapshot, observed.roomID == identity.roomID { snapshot = observed }
                saving = false
                retryingFailedUpdate = false
                failedRequestedChoice = nil
                if let warning = result.warning {
                    notice = warning
                    needsReload = true
                } else {
                    onClose()
                }
            } catch let partial as RoomNotificationSaveFailure {
                guard current, context == identity, request == token else { return }
                handledRevision = retries.revision
                if let observed = partial.snapshot, observed.roomID == identity.roomID { snapshot = observed }
                saving = false
                error = partial.warning
                failedRequestedChoice = requested
                retryingFailedUpdate = true
                needsReload = true
            } catch {
                guard current, context == identity, request == token else { return }
                handledRevision = retries.revision
                saving = false
                self.error = MatrixService.safeError(error)
            }
        }
    }
}
