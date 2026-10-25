import SwiftUI

struct MatrixNotificationDefaultsSection: View {
    private static let pickerWidth: CGFloat = 180
    private static let buttonWidth: CGFloat = 64
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    @ObservedObject private var retries: NotificationSettingsRetryState
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var owner: Context?
    @State private var snapshot: AccountNotificationDefaultsSnapshot?
    @State private var drafts: [AccountNotificationCategory: AccountNotificationMode] = [:]
    @State private var failedRequests: [AccountNotificationCategory: AccountNotificationMode] = [:]
    @State private var acceptedAwaitingReload = Set<AccountNotificationCategory>()
    @State private var loading = false
    @State private var savingCategory: AccountNotificationCategory?
    @State private var savedCategory: AccountNotificationCategory?
    @State private var needsReload = false
    @State private var error: String?
    @State private var notice: String?
    @State private var request = UUID()
    @State private var handledRevision = -1

    init(matrix: MatrixService) {
        self.matrix = matrix
        _retries = ObservedObject(wrappedValue: matrix.notificationRetries)
    }

    private struct Context: Hashable {
        let session: UUID
        let accountID: String?
        let preview: Bool
    }
    private var context: Context {
        Context(session: matrix.notificationSessionID, accountID: matrix.user?.id, preview: matrix.isPreview)
    }
    private var current: Bool { owner == context && context.accountID != nil && !context.preview }
    private var colors: AppColors { appearance.colors }
    private var busy: Bool { loading || savingCategory != nil || retries.isWriting }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp20) {
            HStack(alignment: .top, spacing: m.sp12) {
                Text("Notify me about").font(m.font(.body, .semibold)).foregroundStyle(colors.primaryText)
                Spacer(minLength: 0)
                if current {
                    Button("Reload") { Task { await load() } }.buttonStyle(.link).font(m.font(.meta)).disabled(busy)
                        .accessibilityLabel("Reload notification defaults")
                }
            }
            if context.preview || context.accountID == nil {
                Text("Sign in to change these.").font(m.font(.meta)).foregroundStyle(colors.muted)
            } else if loading {
                HStack(spacing: m.sp8) {
                    ProgressView().controlSize(.small).loadingInterval(.sheetLoading)
                    Text("Loading…").font(m.font(.meta)).foregroundStyle(colors.muted)
                }
            } else if snapshot != nil && current {
                categoryGroup("Encrypted conversations", encrypted: true)
                categoryGroup("Unencrypted conversations", encrypted: false)
            }
            if retries.isWriting && savingCategory == nil {
                ProgressView("Saving…").controlSize(.small).font(m.font(.meta))
            }
            if let notice {
                Label(notice, systemImage: "info.circle").font(m.font(.meta)).foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(m.font(.meta)).foregroundStyle(Color(nsColor: .systemRed)).fixedSize(
                    horizontal: false, vertical: true
                )
                .textSelection(.enabled)
            }
            if needsReload, current {
                Text("Reload, then try again.")
                    .font(m.font(.meta)).foregroundStyle(colors.muted)
            }
        }
        .task(id: context) {
            if owner == nil { owner = context }
            guard current else {
                request = UUID()
                snapshot = nil
                drafts = [:]
                failedRequests = [:]
                acceptedAwaitingReload = []
                loading = false
                savingCategory = nil
                savedCategory = nil
                notice = nil
                error =
                    context.accountID != nil && !context.preview
                    ? "You signed in again. Reopen Preferences." : nil
                return
            }
            await load()
        }
        .onChange(of: retries.revision) { _, _ in
            Task { @MainActor in
                guard current, savingCategory == nil, !retries.isWriting, handledRevision != retries.revision else {
                    return
                }
                await load()
            }
        }
        .onDisappear { request = UUID() }
    }

    private func categoryGroup(_ title: String, encrypted: Bool) -> some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            Label(title, systemImage: encrypted ? "lock" : "lock.open").font(m.font(.meta, .semibold))
                .foregroundStyle(colors.primaryText)
            ForEach(AccountNotificationCategory.allCases.filter { $0.isEncrypted == encrypted }) { category in
                HStack(spacing: m.sp12) {
                    Text(category.isOneToOne ? "Direct messages" : "Group conversations")
                        .font(m.font(.meta)).frame(maxWidth: .infinity, alignment: .leading)
                    Picker(
                        "\(title), \(category.isOneToOne ? "conversations with two people" : "other conversations")",
                        selection: Binding(
                            get: {
                                drafts[category] ?? snapshot?[category] ?? .allMessages
                            },
                            set: {
                                drafts[category] = $0
                                savedCategory = nil
                            })
                    ) {
                        ForEach(AccountNotificationMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.labelsHidden().frame(width: m(Self.pickerWidth)).disabled(busy || needsReload)
                    Button(buttonTitle(category)) { save(category) }.controlSize(.small).frame(
                        width: m(Self.buttonWidth)
                    )
                    .accessibilityLabel("\(buttonTitle(category)) \(category.title)")
                    .disabled(!canSave(category))
                }
            }
        }.padding(m.sp16).frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
    }
    private func canSave(_ category: AccountNotificationCategory) -> Bool {
        guard current, !busy, !needsReload, let draft = drafts[category], let original = snapshot?[category] else {
            return false
        }
        return failedRequests[category] != nil || draft != original
    }
    private func buttonTitle(_ category: AccountNotificationCategory) -> String {
        if savingCategory == category { return "Saving…" }
        if failedRequests[category] != nil { return "Retry" }
        return savedCategory == category ? "Saved" : "Save"
    }
    private func complete(_ value: AccountNotificationDefaultsSnapshot) -> Bool {
        AccountNotificationCategory.allCases.allSatisfy { value[$0] != nil }
    }

    /// A refresh updates baselines without discarding independent unsaved selections.
    /// An uncertain failed request remains explicit retry intent even if cached rules match it.
    private func adopt(
        _ value: AccountNotificationDefaultsSnapshot, acceptedCategory: AccountNotificationCategory? = nil
    ) {
        let previous = snapshot
        for category in AccountNotificationCategory.allCases {
            if let failed = failedRequests[category] {
                drafts[category] = failed
            } else if category == acceptedCategory || acceptedAwaitingReload.contains(category) {
                drafts[category] = value[category]
            } else if drafts[category] == nil || drafts[category] == previous?[category] {
                drafts[category] = value[category]
            }
        }
        snapshot = value
    }

    @MainActor private func load() async {
        guard current, savingCategory == nil, !retries.isWriting else { return }
        let identity = context
        let token = UUID()
        let revision = retries.revision
        request = token
        loading = true
        error = nil
        notice = nil
        do {
            let loaded = try await matrix.loadAccountNotificationDefaults()
            guard !Task.isCancelled, current, context == identity, request == token else { return }
            guard retries.revision == revision, !retries.isWriting else {
                refreshAfterOwnerChange()
                return
            }
            handledRevision = revision
            failedRequests = loaded.pendingRetryModes
            guard complete(loaded) else {
                throw MatrixServiceError.request("Couldn’t read your settings. Reload to try again.")
            }
            adopt(loaded)
            acceptedAwaitingReload = []
            loading = false
            needsReload = false
            if !failedRequests.isEmpty {
                notice = "Saving was interrupted. Choose Retry to finish."
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

    @MainActor private func save(_ category: AccountNotificationCategory) {
        guard canSave(category), let mode = drafts[category] else { return }
        let identity = context
        let token = UUID()
        request = token
        savingCategory = category
        savedCategory = nil
        error = nil
        notice = nil
        Task { @MainActor in
            guard current, context == identity, request == token else { return }
            do {
                let result = try await matrix.saveAccountNotificationDefault(category: category, mode: mode)
                guard current, context == identity, request == token else { return }
                handledRevision = retries.revision
                failedRequests = retries.defaultModes
                if let observed = result.snapshot, complete(observed) { adopt(observed, acceptedCategory: category) }
                savingCategory = nil
                savedCategory = category
                if result.warning != nil || result.snapshot == nil || result.snapshot.map({ !complete($0) }) == true {
                    acceptedAwaitingReload.insert(category)
                    needsReload = true
                    notice =
                        result.warning
                        ?? "Saved, but couldn’t read the result. Reload to check."
                }
            } catch let failure as AccountNotificationDefaultsSaveFailure {
                guard current, context == identity, request == token else { return }
                handledRevision = retries.revision
                failedRequests[category] = mode
                drafts[category] = mode
                if let observed = failure.snapshot, complete(observed) { adopt(observed) }
                savingCategory = nil
                needsReload = true
                error = failure.warning
            } catch {
                guard current, context == identity, request == token else { return }
                handledRevision = retries.revision
                savingCategory = nil
                self.error = MatrixService.safeError(error)
            }
        }
    }
}
