import AppKit
import SwiftUI

struct PersonProfileView: View {
    private static let width: CGFloat = 448
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let people: PeopleService
    var userID: String
    var fallback: ChatUser? = nil
    var onOpenConversation: (String) -> Void
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var messaging = false
    @State private var operation = UUID()
    @State private var error: String?
    @State private var copied = false
    @State private var retryRevision = 0
    private var colors: AppColors { appearance.colors }
    private var account: PeopleAccountIdentity {
        PeopleAccountIdentity(userID: matrix.user?.id, isPreview: matrix.isPreview)
    }
    private var profile: PersonProfile? { people.profile?.id == userID ? people.profile : nil }
    private var name: String { profile?.name ?? (fallback?.id == userID ? fallback?.name : nil) ?? userID }
    private var avatarURL: String? { profile?.avatarURL ?? (fallback?.id == userID ? fallback?.avatarURL : nil) }
    private var ownProfile: Bool { userID == matrix.user?.id }
    private struct Request: Hashable {
        var userID: String
        var account: PeopleAccountIdentity
        var retry: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp20) {
            HStack(alignment: .top) {
                AvatarView(name: name, size: m.avatarLarge, matrix: matrix, source: avatarURL)
                Spacer()
                IconButton(symbol: "xmark", label: "Close profile", role: .secondary, action: close).disabled(messaging)
            }
            VStack(alignment: .leading, spacing: m.sp8) {
                Text(name).font(m.font(.display, .bold)).foregroundStyle(colors.textPrimary).textSelection(
                    .enabled
                ).fixedSize(horizontal: false, vertical: true)
                if ownProfile { Text("You").font(m.font(.meta)).foregroundStyle(colors.textSecondary) }
                if people.statusSupported, let status = profile?.status, !status.isEmpty {
                    Text(status).font(m.font(.body)).foregroundStyle(colors.textBody).textSelection(.enabled).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            Divider().overlay(colors.border)
            VStack(alignment: .leading, spacing: m.sp8) {
                Text("Matrix ID").font(m.font(.meta, .semibold))
                HStack(alignment: .top, spacing: m.sp8) {
                    Text(userID).font(m.font(.meta, design: .monospaced)).foregroundStyle(colors.textSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    IconButton(
                        symbol: copied ? "checkmark" : "doc.on.doc",
                        label: copied ? "Copied" : "Copy Matrix ID", role: .meta
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(userID, forType: .string)
                        copied = true
                    }
                }
            }
            if people.profileState == "loading" {
                HStack(spacing: m.sp8) {
                    DelayedProgress(interval: .profileLoading)
                    Text("Loading…").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                }
            } else if people.profileState == "error" || profile?.profileAvailable == false {
                HStack(spacing: m.sp8) {
                    Text(people.profileErrorMessage ?? "No public profile").font(m.font(.meta)).foregroundStyle(
                        colors.textSecondary
                    ).fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { loadProfile() }.buttonStyle(.textLink).font(m.font(.meta)).disabled(messaging)
                }
            }
            if let error { InlineErrorView(message: error).clipShape(RoundedRectangle(cornerRadius: m.radius)) }
            HStack(spacing: m.sp12) {
                if messaging {
                    DelayedProgress()
                }
                Spacer(minLength: 0)
                Button("Close", action: close).keyboardShortcut(.cancelAction).disabled(messaging)
                Button(action: message) {
                    Label("Message", systemImage: "bubble.left.and.bubble.right").font(
                        m.font(.secondary, .semibold)
                    ).padding(.horizontal, m.sp8).padding(.vertical, m.sp4)
                }
                .buttonStyle(.primary)
                .disabled(
                    messaging || matrix.isPreview || ownProfile || (try? PeopleMapping.validatedID(userID)) == nil
                )
            }
        }
        .padding(m.sp24).sheetSize(width: Self.width).background(colors.canvas).foregroundStyle(colors.textBody)
        .interactiveDismissDisabled(messaging)
        .task(id: Request(userID: userID, account: account, retry: retryRevision)) {
            await people.loadProfile(userID: userID, fallback: fallback)
        }
        .task(id: copied) {
            if copied {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
        }
        .onChange(of: userID) { _, _ in
            operation = UUID()
            messaging = false
            error = nil
            copied = false
        }
        .onChange(of: account) { _, _ in
            operation = UUID()
            messaging = false
            error = nil
            close()
        }
        .onDisappear {
            operation = UUID()
            people.dismissProfile()
        }
        .onExitCommand { if !messaging { close() } }
    }

    private func close() {
        guard !messaging else { return }
        operation = UUID()
        people.dismissProfile()
        onClose()
    }
    private func loadProfile() { retryRevision += 1 }
    private func message() {
        guard !messaging, !matrix.isPreview, !ownProfile else { return }
        let request = UUID()
        let expectedAccount = account
        let target = userID
        operation = request
        messaging = true
        error = nil
        Task { @MainActor in
            guard operation == request, account == expectedAccount, userID == target else { return }
            do {
                let roomID = try await matrix.createDM(userID: target)
                guard operation == request, account == expectedAccount, userID == target, !Task.isCancelled else {
                    return
                }
                messaging = false
                people.dismissProfile()
                onOpenConversation(roomID)
                onClose()
            } catch {
                guard operation == request, account == expectedAccount, userID == target else { return }
                self.error = MatrixService.safeError(error)
                messaging = false
            }
        }
    }
}
