import SwiftUI

struct MediaCaptionEditor: View {
    private static let width: CGFloat = 512
    private static let editorHeight: CGFloat = 128
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let target: MessageActionTarget
    let onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var snapshot: MediaCaptionSnapshot?
    @State private var draft: String?
    @State private var initialized = false
    @State private var loading = false
    @State private var saving = false
    @State private var accepted = false
    @State private var notice: String?
    @State private var error: String?
    @State private var presented = true
    @State private var request = UUID()

    private var current: Bool { presented && matrix.isCurrentMessageAction(target) }
    private var colors: AppColors { appearance.colors }
    private var canSave: Bool {
        current && !loading && !saving && !accepted && snapshot != nil && draft != snapshot?.caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp16) {
            HStack {
                Text("Edit caption").font(m.font(.header, .bold))
                Spacer()
                IconButton(symbol: "xmark", label: "Close", role: .body, action: onClose).disabled(
                    saving)
            }
            if accepted {
                Label("Caption saved", systemImage: "checkmark.circle").foregroundStyle(colors.success)
                HStack {
                    Spacer()
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                }
            } else {
                Text(snapshot?.filename ?? target.message.attachment?.name ?? "Attachment")
                    .font(m.font(.secondary, .semibold)).textSelection(.enabled)
                if loading {
                    HStack {
                        DelayedProgress(interval: .sheetLoading)
                        Text("Loading…").font(m.font(.meta))
                    }
                }
                if let snapshot {
                    if notice != nil {
                        VStack(alignment: .leading, spacing: m.sp4) {
                            Text("Current caption").font(m.font(.caption, .semibold)).foregroundStyle(
                                colors.textSecondary)
                            Text(snapshot.caption ?? "No caption").font(m.font(.meta)).textSelection(.enabled)
                        }.padding(m.sp12).frame(maxWidth: .infinity, alignment: .leading).background(
                            colors.raised, in: RoundedRectangle(cornerRadius: m.radius))
                    }
                    TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0.isEmpty ? nil : $0 }))
                        .font(m.font(.body)).frame(height: m(Self.editorHeight)).padding(m.sp8)
                        .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(colors.border))
                        .accessibilityLabel("Attachment caption").disabled(loading || saving || !current)
                    Button("Remove caption") { draft = nil }.buttonStyle(.textLink)
                        .disabled(saving || loading || !current || (draft == nil && snapshot.caption == nil))
                }
                if let notice {
                    Text(notice).font(m.font(.meta)).foregroundStyle(colors.accent).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let error { InlineErrorView(message: error).clipShape(RoundedRectangle(cornerRadius: m.radius)) }
                if snapshot == nil && !loading {
                    Button("Reload") { Task { await load() } }.buttonStyle(.textLink).disabled(
                        saving || !current)
                }
                HStack {
                    Button("Cancel", action: onClose).keyboardShortcut(.cancelAction).disabled(saving)
                    Spacer()
                    if saving { DelayedProgress() }
                    Button(saving ? "Saving…" : "Save", action: save).buttonStyle(.primary).disabled(
                        !canSave)
                }
            }
        }.padding(m.sp24).sheetSize(width: Self.width).background(colors.canvas).foregroundStyle(colors.textBody)
            .interactiveDismissDisabled(saving)
            .task(id: matrix.mediaCaptionSourceRevision(target)) { await load() }
            .onDisappear {
                presented = false
                request = UUID()
            }
            .onExitCommand { if !saving { onClose() } }
    }
    @MainActor private func adopt(_ fresh: MediaCaptionSnapshot) {
        let previous = snapshot
        if !initialized {
            draft = fresh.caption
            initialized = true
        } else if previous?.revision != fresh.revision {
            notice = "The caption changed. Your draft is kept; check it, then save."
        }
        snapshot = previous?.revision == fresh.revision ? previous : fresh
    }
    @MainActor private func load() async {
        guard !Task.isCancelled, current, !saving, !accepted else { return }
        let token = UUID()
        request = token
        loading = true
        error = nil
        defer { if request == token { loading = false } }
        do {
            let fresh = try await matrix.loadMediaCaption(target)
            guard !Task.isCancelled, current, request == token, !saving, !accepted else { return }
            adopt(fresh)
        } catch {
            guard !Task.isCancelled, current, request == token, !saving, !accepted else { return }
            snapshot = nil
            self.error =
                error is CancellationError
                ? "This message is gone."
                : MatrixService.safeError(error)
        }
    }
    @MainActor private func save() {
        guard canSave, let submitted = snapshot else { return }
        let caption = draft
        let token = UUID()
        request = token
        saving = true
        error = nil
        notice = nil
        Task { @MainActor in
            guard current, request == token else {
                saving = false
                return
            }
            do {
                let result = try await matrix.saveMediaCaption(submitted, caption: caption)
                accepted = result.queued
                saving = false
                if !result.queued, current { onClose() }
            } catch let changed as MediaCaptionReviewChanged {
                guard current, request == token else { return }
                adopt(changed.snapshot)
                notice = changed.localizedDescription
                saving = false
            } catch {
                guard current, request == token else { return }
                saving = false
                if error is CancellationError {
                    snapshot = nil
                    self.error = "The message changed. Reload it, then save."
                } else {
                    self.error = MatrixService.safeError(error)
                }
            }
        }
    }
}
