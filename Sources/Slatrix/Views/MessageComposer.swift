import AppKit
import SwiftUI

extension MentionSearch.Candidate {
    fileprivate var name: String {
        switch self {
        case .member(let member): member.name
        case .room: "@room"
        }
    }
}

struct MessageComposer: View {
    @Binding var text: String
    var placeholder: String
    var members: [ChatUser]
    /// The conversation's senders, latest first, read as you type an @ query.
    var recentSenders: () -> [String] = { [] }
    var isEditing: Bool = false
    var onSend: (String, [URL]) async throws -> Void
    var onTyping: (Bool) -> Void
    var onCancelEdit: (() -> Void)? = nil
    var onSendText: ((String) async throws -> Void)? = nil
    var onSendFile: ((URL) async throws -> Void)? = nil
    var queuedFiles: Binding<[URL]>? = nil
    var sendingState: Binding<Bool>? = nil
    var onError: ((String) -> Void)? = nil
    var allowsSend = true
    var onDiscardAttachments: (([URL]) -> Void)? = nil
    var requiresTextForSend = false
    /// Slack's Esc, ⇧Esc and ↑ when the composer has no use for them; returns whether the key was used.
    var onConversationKey: ((ConversationKeys.Action) -> Bool)? = nil
    /// The composer ⌘U attaches to when no composer has focus: the conversation's, not a thread's.
    var isPrimary = false

    @StateObject private var editor = ComposerEditorState()
    @State private var localAttachments: [URL] = []
    @State private var localSending = false
    @State private var errorMessage: String?
    @State private var attachmentError: String?
    @State private var preparingAttachments = false
    @State private var importTask: Task<Void, Never>?
    @State private var importGeneration = UUID()
    @State private var isActive = true
    @State private var showFormatting = true
    @State private var mention: MentionSearch.Suggestions?
    @State private var mentionIndex = 0
    @State private var typingTask: Task<Void, Never>?
    @State private var linkDraft: ComposerLinkDraft?
    @FocusState private var linkFocused: Bool
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(Popovers.self) private var popovers: Popovers?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.metrics) private var m

    private var attachments: [URL] {
        get { queuedFiles?.wrappedValue ?? localAttachments }
        nonmutating set {
            if let queuedFiles { queuedFiles.wrappedValue = newValue } else { localAttachments = newValue }
        }
    }

    private var sending: Bool {
        get { sendingState?.wrappedValue ?? localSending }
        nonmutating set {
            if let sendingState { sendingState.wrappedValue = newValue } else { localSending = newValue }
        }
    }

    private var canSend: Bool {
        allowsSend && !sending && !preparingAttachments
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (!requiresTextForSend && !isEditing && !attachments.isEmpty))
    }
    private var colors: AppColors { appearance.colors }
    private var muted: Color { colors.textSecondary }
    private var mentionMatches: [MentionSearch.Candidate] { mention?.candidates ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                HStack(spacing: m.sp8) {
                    RoundedRectangle(cornerRadius: m.sp2).fill(colors.accent).frame(width: m(3), height: m.sp16)
                    Text("Editing message").font(m.font(.meta, .medium))
                    Spacer()
                    Button {
                        onCancelEdit?()
                    } label: {
                        Image(systemName: "xmark").font(m.font(.caption, .semibold))
                    }
                    .buttonStyle(.row).help("Cancel editing (Escape)").accessibilityLabel("Cancel editing")
                }.padding(.horizontal, m.sp12).padding(.top, m.sp12).padding(.bottom, m.sp4)
            }
            // Hiding the toolbar keeps its row, so toggling it never resizes the composer or the conversation.
            formattingToolbar.opacity(showFormatting ? 1 : 0).disabled(!showFormatting)
                .accessibilityHidden(!showFormatting)
            ZStack(alignment: .topLeading) {
                if text.isEmpty && editor.formats.block == nil {
                    Text(placeholder)
                        .font(m.font(.body)).foregroundStyle(muted)
                        .padding(.leading, m.sp12).padding(.top, m.sp8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerNativeEditor(
                    text: $text, state: editor, members: members, mentionText: NSColor(colors.mentionText),
                    mentionFill: NSColor(colors.mentionFill), textColor: NSColor(colors.textBody),
                    linkColor: NSColor(colors.accent), enabled: !sending,
                    acceptsAttachments: !sending && !isEditing && !preparingAttachments, onTextChange: changed,
                    onSelectionChange: updateMention, onSend: send, onSpecialKey: specialKey, onLink: editLink,
                    onAttachments: queueInput, onAttachmentError: attachmentFailed
                )
                .accessibilityLabel(isEditing ? "Edit message" : placeholder)
                .accessibilityHint("Drop or paste files to attach.")
            }
            if !attachments.isEmpty && !isEditing { attachmentStrip }
            HStack(spacing: m.sp4) {
                iconButton("plus", label: "Attach files", circular: true) { chooseFiles() }.disabled(
                    sending || isEditing || preparingAttachments)
                Button {
                    showFormatting.toggle()
                    editor.focus()
                } label: {
                    Text("Aa").font(m.font(.body)).underline(showFormatting, color: muted)
                        .frame(width: m.iconButton, height: m.iconButton).contentShape(Rectangle())
                }.buttonStyle(.icon).foregroundStyle(muted).help(showFormatting ? "Hide formatting" : "Show formatting")
                    .accessibilityLabel(showFormatting ? "Hide formatting" : "Show formatting")
                iconButton("face.smiling", label: "Emoji") {
                    popovers?.show(.emoji(EmojiPick { [editor] in editor.insert($0) }))
                }
                iconButton("at", label: "Mention someone") {
                    editor.insert("@")
                    editor.focus()
                }.disabled(members.isEmpty)
                Spacer(minLength: m.sp4)
                if sending || preparingAttachments {
                    DelayedProgress().accessibilityLabel(
                        preparingAttachments ? "Preparing attachments" : "Sending message")
                    if preparingAttachments {
                        Text("Preparing attachments…").font(m.font(.caption)).foregroundStyle(muted)
                    }
                } else {
                    // Shown whole or not at all, so a narrow pane or large zoom never shows "Shift…"; only while
                    // typing, as in Slack.
                    ViewThatFits(in: .horizontal) {
                        Text("Shift + Return to add a new line").font(m.font(.caption)).foregroundStyle(muted)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }.layoutPriority(-1).opacity(text.isEmpty || isEditing ? 0 : 1)
                }
                Button(action: send) {
                    HStack(spacing: m.sp8) {
                        Image(systemName: "paperplane.fill").font(m.font(.secondary))
                        Rectangle().fill(colors.onAccent.opacity(0.22)).frame(width: 1, height: m.sp16)
                        Text(isEditing ? "Save" : "↵").font(m.font(.meta, .medium))
                    }.foregroundStyle(canSend ? colors.onAccent : muted)
                        .padding(.horizontal, m.sp12).frame(height: m.row)
                        .background(
                            canSend ? colors.buttonPrimary : muted.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: m.radiusSmall)
                        )
                        .contentShape(Rectangle())
                }.buttonStyle(.row).disabled(!canSend)
                    .help(isEditing ? "Save changes (Return)" : "Send message (Return)")
                    .accessibilityLabel(isEditing ? "Save changes" : "Send message")
            }.padding(.horizontal, m.sp12).padding(.bottom, m.sp8).disabled(sending)
        }
        .background(colors.overlay, in: RoundedRectangle(cornerRadius: m.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: m.radiusLarge).strokeBorder(
                editor.isFocused ? colors.textSecondary : colors.borderStrong, lineWidth: 1)
        )
        // Suggestions, errors and hints float above the composer instead of growing it.
        .overlay(alignment: .topLeading) {
            floating.alignmentGuide(.top) { $0[.bottom] + m.sp8 }
        }
        .onAppear { isActive = true }
        .task(id: (isEditing || requiresTextForSend) && isEnabled) {
            guard isEditing || requiresTextForSend, isEnabled else { return }
            for _ in 0..<20 {
                guard !Task.isCancelled, isActive, !sending else { return }
                if let view = editor.textView, let window = view.window,
                    window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil
                {
                    editor.focus()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
        .onDisappear {
            isActive = false
            importGeneration = UUID()
            importTask?.cancel()
            importTask = nil
            preparingAttachments = false
            typingTask?.cancel()
            onTyping(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuAction)) { notification in
            guard notification.userInfo?["action"] as? String == "attach", !isEditing, isEnabled else { return }
            let focused = NSApp.keyWindow?.firstResponder
            if focused === editor.textView || (isPrimary && !(focused is ComposerTextView)) { chooseFiles() }
        }
        .onExitCommand {
            if mention != nil {
                mention = nil
            } else if isEditing {
                onCancelEdit?()
            }
        }
        .uploadIntake(isEnabled && !sending && !isEditing && !preparingAttachments ? queueInput as UploadIntake : nil)
    }

    private var floating: some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            if let draft = Binding($linkDraft) { linkCard(draft) }
            if !mentionMatches.isEmpty { mentionSuggestions }
            Group {
                if let errorMessage {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                        Text(errorMessage).textSelection(.enabled)
                        Spacer(minLength: m.sp4)
                        Button("Try again", action: send).buttonStyle(.textLink).disabled(!canSend)
                    }.font(m.font(.meta)).foregroundStyle(colors.destructive)
                        .accessibilityElement(children: .combine)
                }
                if let attachmentError {
                    HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                        Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                        Text(attachmentError)
                        Spacer(minLength: m.sp4)
                        Button {
                            self.attachmentError = nil
                        } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.row).accessibilityLabel("Dismiss attachment error")
                    }.font(m.font(.meta)).foregroundStyle(colors.destructive).accessibilityElement(
                        children: .combine)
                }
                if requiresTextForSend && !attachments.isEmpty {
                    Text("Add a message to reply").font(m.font(.caption)).foregroundStyle(muted)
                }
            }
            .padding(.horizontal, m.sp12).padding(.vertical, m.sp8)
            .background(colors.overlay, in: RoundedRectangle(cornerRadius: m.radiusLarge))
        }
    }

    /// Slack's bar and order; each button shows whether its format is on where the caret is.
    private var formattingToolbar: some View {
        let formats = editor.formats
        return HStack(spacing: 0) {
            formatButton("bold", label: "Bold", keys: "⌘B", on: formats.style.contains(.bold)) {
                editor.toggle(.bold)
            }
            formatButton("italic", label: "Italic", keys: "⌘I", on: formats.style.contains(.italic)) {
                editor.toggle(.italic)
            }
            formatButton("strikethrough", label: "Strikethrough", keys: "⇧⌘X", on: formats.style.contains(.strike)) {
                editor.toggle(.strike)
            }
            toolbarDivider
            formatButton("link", label: "Link", keys: "⇧⌘U", on: false, action: editLink)
            toolbarDivider
            formatButton("list.number", label: "Numbered list", keys: "⇧⌘7", on: formats.block == .ordered) {
                editor.toggle(block: .ordered)
            }
            formatButton("list.bullet", label: "Bulleted list", keys: "⇧⌘8", on: formats.block == .bullet) {
                editor.toggle(block: .bullet)
            }
            toolbarDivider
            formatButton("text.quote", label: "Quote", keys: "⇧⌘9", on: formats.block == .quote) {
                editor.toggle(block: .quote)
            }
            formatButton(
                "chevron.left.forwardslash.chevron.right", label: "Code", keys: "⇧⌘C",
                on: formats.style.contains(.code)
            ) { editor.toggle(.code) }
            formatButton("curlybraces.square", label: "Code block", keys: "⌥⇧⌘C", on: formats.block == .code) {
                editor.toggle(block: .code)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, m.sp8).padding(.top, m.sp8).disabled(sending)
            .accessibilityElement(children: .contain).accessibilityLabel("Message formatting")
    }

    private var toolbarDivider: some View {
        Rectangle().fill(muted.opacity(0.25)).frame(width: 1, height: m.sp16).padding(.horizontal, m.sp4)
    }

    private func formatButton(
        _ icon: String, label: String, keys: String, on: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(m.font(.secondary)).frame(width: m.iconButton, height: m.iconButton)
                .background(on ? muted.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: m.radiusSmall))
                .contentShape(Rectangle())
        }
        .buttonStyle(.icon).foregroundStyle(on ? colors.textPrimary : muted).help("\(label) (\(keys))")
        .accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }

    private func editLink() {
        linkDraft = editor.linkDraft()
    }

    private func saveLink() {
        guard let linkDraft, linkDraft.isValid else { return }
        editor.setLink(linkDraft)
        self.linkDraft = nil
    }

    /// Slack's link card: the text and its address, over the composer.
    private func linkCard(_ draft: Binding<ComposerLinkDraft>) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            TextField("Text", text: draft.text).textFieldStyle(.field)
            TextField("Link", text: draft.url).textFieldStyle(.field).focused($linkFocused).onSubmit(saveLink)
            HStack(spacing: m.sp8) {
                Spacer()
                Button("Cancel") {
                    linkDraft = nil
                    editor.focus()
                }.buttonStyle(.secondary)
                Button("Save", action: saveLink).buttonStyle(.primary).disabled(!draft.wrappedValue.isValid)
            }
        }
        .padding(m.sp12).frame(width: m.popoverWidth)
        .background(colors.overlay, in: RoundedRectangle(cornerRadius: m.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
        .elevation(.e2, cornerRadius: m.radiusLarge)
        .onAppear { linkFocused = true }
        .onExitCommand {
            linkDraft = nil
            editor.focus()
        }
    }

    private func iconButton(_ icon: String, label: String, circular: Bool = false, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: icon).font(m.font(.body)).frame(width: m.iconButton, height: m.iconButton)
                .background(circular ? muted.opacity(0.12) : Color.clear, in: Circle()).contentShape(Rectangle())
        }.buttonStyle(.icon).foregroundStyle(muted).help(label).accessibilityLabel(label)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: m.sp8) {
                ForEach(attachments, id: \.self) { url in
                    StagedAttachmentTile(url: url) {
                        attachments.removeAll { $0 == url }
                        discardAttachments([url])
                    }.disabled(sending || preparingAttachments)
                }
            }.padding(.horizontal, m.sp12)
        }.scrollIndicators(.hidden).padding(.bottom, m.sp8)
    }

    /// Slack's @ list: eight rows at once, the rest by scrolling or the arrow keys, which keep the selection in view.
    private var mentionSuggestions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, so a bare @ in a big room draws only the rows on screen.
                LazyVStack(spacing: 0) {
                    ForEach(Array(mentionMatches.enumerated()), id: \.element) { index, candidate in
                        mentionRow(candidate, selected: index == mentionIndex).id(index)
                    }
                }.padding(m.sp4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: mentionIndex) { proxy.scrollTo(mentionIndex) }
        }
        .frame(height: CGFloat(min(mentionMatches.count, 8)) * m.menuRow + 2 * m.sp4)
        .background(colors.overlay, in: RoundedRectangle(cornerRadius: m.radiusLarge))
        .clipShape(RoundedRectangle(cornerRadius: m.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
        .elevation(.e2, cornerRadius: m.radiusLarge)
    }

    @ViewBuilder
    private func mentionRow(_ candidate: MentionSearch.Candidate, selected: Bool) -> some View {
        switch candidate {
        case .member(let member):
            // The ID tells apart people who share a name; otherwise it is noise.
            let twin = mentionMatches.contains { $0 != candidate && $0.name == member.name }
            let detail = [twin ? member.id : nil, member.membership == "invite" ? "Invited" : nil].compactMap { $0 }
            MenuRow(
                title: member.name, detail: detail.isEmpty ? nil : detail.joined(separator: " · "), selected: selected
            ) {
                chooseMention(candidate)
            } icon: {
                AvatarView(name: member.name, size: m.avatarMedium)
            }
        case .room:
            MenuRow(title: "@room", detail: "Notify everyone in this conversation", selected: selected) {
                chooseMention(candidate)
            } icon: {
                Image(systemName: "megaphone").font(m.font(.secondary))
            }
        }
    }

    private func changed(_ value: String, _ range: NSRange) {
        errorMessage = nil
        typingTask?.cancel()
        onTyping(!value.isEmpty)
        typingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            onTyping(false)
        }
        updateMention(value, range)
    }

    private func updateMention(_ value: String, _ range: NSRange) {
        let prefix = (value as NSString).substring(to: min(range.location, (value as NSString).length))
        let found =
            prefix.contains("@")
            ? MentionSearch.suggestions(before: prefix, members: members, recentSenders: recentSenders()) : nil
        // An @ inside a finished mention starts no query.
        mention = found.flatMap { editor.isMention(at: $0.range.location) ? nil : $0 }
        mentionIndex = 0
    }

    private func specialKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            if mention != nil {
                mention = nil
                return true
            }
            if isEditing {
                onCancelEdit?()
                return true
            }
        }
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if !mentionMatches.isEmpty && modifiers.isEmpty {
            switch event.keyCode {
            case 125: mentionIndex = (mentionIndex + 1) % mentionMatches.count
            case 126: mentionIndex = (mentionIndex - 1 + mentionMatches.count) % mentionMatches.count
            case 36, 48, 76: chooseMention(mentionMatches[min(mentionIndex, mentionMatches.count - 1)])
            default: return false
            }
            return true
        }
        guard !isEditing, let onConversationKey,
            let key: ConversationKeys.Key = event.keyCode == 53 ? .escape : event.keyCode == 126 ? .up : nil,
            let action = ConversationKeys.action(
                key, shift: modifiers.contains(.shift), otherModifiers: !modifiers.subtracting(.shift).isEmpty,
                composerText: text)
        else { return false }
        return onConversationKey(action)
    }

    private func chooseMention(_ candidate: MentionSearch.Candidate) {
        switch candidate {
        case .member(let member): editor.insertMention(member, replacing: mention?.range)
        case .room: editor.insert("@room ", replacing: mention?.range)
        }
        mention = nil
        editor.focus()
    }

    private func chooseFiles() {
        guard isActive, !sending, !isEditing, !preparingAttachments else { return }
        let generation = importGeneration
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        if let window = editor.textView?.window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, isActive, importGeneration == generation { _ = queueInput(.files(panel.urls)) }
            }
        } else if panel.runModal() == .OK, isActive, importGeneration == generation {
            _ = queueInput(.files(panel.urls))
        }
    }

    private func attachmentFailed(_ message: String) {
        attachmentError = message
        onError?(message)
    }

    private func attachmentFailed(_ error: Error) {
        attachmentFailed(
            (error as? ComposerAttachmentImporter.Failure)?.message
                ?? "Couldn’t attach the file. Check that it’s readable and try again.")
    }

    private func queueInput(_ input: ComposerAttachmentInput) -> Bool {
        guard isActive, !sending, !isEditing, !preparingAttachments else {
            if isActive {
                attachmentFailed(
                    isEditing
                        ? "Finish editing before attaching files."
                        : "Wait for the current attachment to finish.")
            }
            return false
        }
        preparingAttachments = true
        attachmentError = nil
        let generation = importGeneration
        let existing = attachments
        importTask = Task { @MainActor in
            defer {
                if generation == importGeneration {
                    preparingAttachments = false
                    importTask = nil
                }
            }
            do {
                let staged = try await ComposerAttachmentImporter.stage(input, existing: existing)
                guard !Task.isCancelled, isActive, generation == importGeneration else {
                    Task.detached { ComposerAttachmentImporter.discard(staged) }
                    return
                }
                attachments = existing + staged
                // Root's account-generation binding rejects writes from a signed-out composer.
                guard staged.allSatisfy({ attachments.contains($0) }) else {
                    Task.detached { ComposerAttachmentImporter.discard(staged) }
                    return
                }
                errorMessage = nil
                editor.focus()
            } catch is CancellationError {} catch {
                if isActive, generation == importGeneration { attachmentFailed(error) }
            }
        }
        return true
    }

    private func send() {
        guard canSend else { return }
        do { if !isEditing { try ComposerAttachmentImporter.validateQueue(attachments) } } catch {
            attachmentFailed(error)
            return
        }
        sending = true
        errorMessage = nil
        mention = nil
        typingTask?.cancel()
        onTyping(false)
        let body = text
        let files = isEditing ? [] : attachments
        Task { @MainActor in
            do {
                if let onSendText, let onSendFile {
                    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try await onSendText(body)
                        text = ""
                        if isEditing { onCancelEdit?() }
                    }
                    if !isEditing {
                        for file in files {
                            try await onSendFile(file)
                            attachments.removeAll { $0 == file }
                            discardAttachments([file])
                        }
                    }
                } else {
                    try await onSend(body, files)
                    text = ""
                    if isEditing {
                        onCancelEdit?()
                    } else {
                        attachments = []
                        discardAttachments(files)
                    }
                }
                editor.focus()
            } catch {
                let message =
                    error is AttachmentDraftError ? error.localizedDescription : MatrixService.safeError(error)
                errorMessage = message
                onError?(message)
            }
            sending = false
        }
    }

    private func discardAttachments(_ urls: [URL]) {
        if let onDiscardAttachments {
            onDiscardAttachments(urls)
        } else {
            Task.detached { ComposerAttachmentImporter.discard(urls) }
        }
    }
}

/// What the caret or selection has on, which the formatting bar shows.
private struct ComposerFormats: Equatable {
    var style: MessageTextStyle = []
    var block: ComposerBlock?
}

/// The text, range and address the link card edits.
private struct ComposerLinkDraft: Equatable {
    var range: NSRange
    var text: String
    var url: String

    /// The address as a link, "example.org" meaning https; nil when it's empty or not a safe link.
    var link: URL? {
        let address = url.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return nil }
        return MessageBodyRenderer.safeLink(address.contains(":") ? address : "https://" + address)
    }
    /// An empty address removes the link.
    var isValid: Bool { url.trimmingCharacters(in: .whitespaces).isEmpty || link != nil }
}

@MainActor private final class ComposerEditorState: ObservableObject {
    @Published var isFocused = false
    @Published var formats = ComposerFormats()
    weak var textView: ComposerTextView?

    func focus() { if let textView { textView.window?.makeFirstResponder(textView) } }

    func insert(_ string: String, replacing range: NSRange? = nil, selection: NSRange? = nil) {
        guard let textView, textView.isEditable else { return }
        let selected = range ?? textView.selectedRange()
        textView.insertText(string, replacementRange: selected)
        if let selection { textView.setSelectedRange(selection) }
        focus()
    }

    /// Inserts text that may hold mention tokens, which `insertText` would flatten.
    func insert(_ value: NSAttributedString, replacing range: NSRange? = nil, selection: NSRange? = nil) {
        guard let textView, textView.isEditable else { return }
        let selected = range ?? textView.selectedRange()
        guard textView.shouldChangeText(in: selected, replacementString: value.string) else { return }
        textView.textStorage?.replaceCharacters(in: selected, with: value)
        textView.didChangeText()
        textView.setSelectedRange(selection ?? NSRange(location: selected.location + value.length, length: 0))
        focus()
    }

    func insertMention(_ member: ChatUser, replacing range: NSRange?) {
        guard let textView else { return }
        let token = NSMutableAttributedString(
            string: "@" + member.name, attributes: textView.typing(mention: ComposerMention(userID: member.id)))
        token.append(NSAttributedString(string: " ", attributes: textView.typingAttributes))
        insert(token, replacing: range)
    }

    func isMention(at location: Int) -> Bool {
        guard let storage = textView?.textStorage, location < storage.length else { return false }
        return storage.attribute(.composerMention, at: location, effectiveRange: nil) != nil
    }

    func toggle(_ style: MessageTextStyle) {
        textView?.toggle(style)
        focus()
    }

    func toggle(block: ComposerBlock) {
        textView?.toggle(block: block)
        focus()
    }

    func linkDraft() -> ComposerLinkDraft? { textView?.linkDraft() }

    func setLink(_ draft: ComposerLinkDraft) {
        textView?.setLink(draft)
        focus()
    }
}

private struct ComposerNativeEditor: NSViewRepresentable {
    static let minHeight: CGFloat = 60
    static let maxHeight: CGFloat = 160
    /// Matrix HTML, as `ComposerFormat` writes it.
    @Binding var text: String
    var state: ComposerEditorState
    /// Names the bare IDs of messages sent before tokens existed.
    var members: [ChatUser]
    var mentionText: NSColor
    var mentionFill: NSColor
    /// The theme's, for quote bars and code fills; the text itself is the system's, which follows the window.
    var textColor: NSColor
    var linkColor: NSColor
    var enabled: Bool
    var acceptsAttachments: Bool
    var onTextChange: (String, NSRange) -> Void
    var onSelectionChange: (String, NSRange) -> Void
    var onSend: () -> Void
    var onSpecialKey: (NSEvent) -> Bool
    var onLink: () -> Void
    var onAttachments: (ComposerAttachmentInput) -> Bool
    var onAttachmentError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The editor grows with its text in the same layout pass as the keystroke, never a frame later.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let m = context.environment.metrics
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? nsView.frame.width
        let minimum = m(Self.minHeight)
        guard width > 2 * m.sp12, let view = nsView.documentView as? NSTextView, let manager = view.layoutManager,
            let container = view.textContainer
        else { return CGSize(width: width, height: minimum) }
        let textWidth = width - 2 * m.sp12
        if abs(container.size.width - textWidth) > 0.5 {
            container.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        let used = ceil(manager.usedRect(for: container).height) + 2 * m.sp8
        return CGSize(width: width, height: min(m(Self.maxHeight), max(minimum, used)))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(ComposerLayoutManager())
        view.textStorage?.delegate = view
        // Rich, so typing next to bold stays bold; paste reads only plain text and HTML, never fonts or colors.
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.insertionPointColor = .labelColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.allowsUndo = true
        view.delegate = context.coordinator
        // AppKit registers a text view for dragged text only when it becomes editable, and this one starts editable.
        view.registerForDraggedTypes(view.acceptableDragTypes)
        view.setAccessibilityLabel("Message editor")
        scroll.documentView = view
        state.textView = view
        configure(view, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        configure(view, context: context)
        if text != context.coordinator.text {
            context.coordinator.synchronizing = true
            let previous = view.selectedRange()
            view.load(text, members: members)
            view.setSelectedRange(NSRange(location: min(previous.location, view.string.utf16.count), length: 0))
            context.coordinator.text = text
            context.coordinator.synchronizing = false
            // After this update, which mustn't publish.
            Task { @MainActor in view.publishFormats() }
        }
        view.isEditable = enabled
    }

    private func configure(_ view: ComposerTextView, context: Context) {
        let m = context.environment.metrics
        let inset = NSSize(width: m.sp12, height: m.sp8)
        if view.textContainerInset != inset { view.textContainerInset = inset }
        view.onSend = onSend
        view.onSpecialKey = onSpecialKey
        view.onLink = onLink
        view.acceptsAttachments = acceptsAttachments
        view.onAttachments = onAttachments
        view.onAttachmentError = onAttachmentError
        view.onFormatsChange = { [weak state] formats in
            if state?.formats != formats { state?.formats = formats }
        }
        view.style(
            fontSize: m.size(.body), text: textColor, mentionText: mentionText, mentionFill: mentionFill,
            link: linkColor)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerNativeEditor
        var synchronizing = false
        /// The draft the editor last showed or wrote.
        var text = ""
        init(_ parent: ComposerNativeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerTextView else { return }
            text = view.draft
            parent.text = text
            parent.onTextChange(view.string, view.selectedRange())
        }
        func textView(
            _ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
            toCharacterRange new: NSRange
        ) -> NSRange {
            (textView as? ComposerTextView)?.outsideMentions(new, from: old) ?? new
        }
        func textDidBeginEditing(_ notification: Notification) { parent.state.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.state.isFocused = false }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !synchronizing else { return }
            guard let view = notification.object as? ComposerTextView else { return }
            view.publishFormats()
            parent.onSelectionChange(view.string, view.selectedRange())
        }
    }
}

extension NSAttributedString.Key {
    fileprivate static let composerMention = NSAttributedString.Key("SlatrixComposerMention")
    /// `MessageTextStyle`'s raw value.
    fileprivate static let composerStyle = NSAttributedString.Key("SlatrixComposerStyle")
    /// `ComposerBlock`'s raw value, on every character of its paragraph.
    fileprivate static let composerBlock = NSAttributedString.Key("SlatrixComposerBlock")
    fileprivate static let composerLink = NSAttributedString.Key("SlatrixComposerLink")
}

/// A token's person. An object, so two adjacent tokens for one person stay two tokens.
private final class ComposerMention: NSObject {
    let userID: String
    init(userID: String) { self.userID = userID }
}

/// Slack's composer: formatting shows as it will be sent, and no Markdown is ever on screen. The storage holds what
/// each character is (`.composerStyle`, `.composerBlock`, a link, a mention) and everything else is derived from it.
private final class ComposerTextView: NSTextView, NSTextStorageDelegate {
    var onSend: (() -> Void)?
    var onSpecialKey: ((NSEvent) -> Bool)?
    var onLink: (() -> Void)?
    var onFormatsChange: ((ComposerFormats) -> Void)?
    var acceptsAttachments = true
    var onAttachments: ((ComposerAttachmentInput) -> Bool)?
    var onAttachmentError: ((String) -> Void)?
    private var fontSize: CGFloat = 0
    private var mentionText = NSColor.linkColor
    private var mentionFill = NSColor.clear
    private var linkColor = NSColor.linkColor
    private var themeText = NSColor.textColor

    // MARK: How text looks, from what it is

    func style(fontSize: CGFloat, text: NSColor, mentionText: NSColor, mentionFill: NSColor, link: NSColor) {
        guard
            fontSize != self.fontSize || mentionText != self.mentionText || mentionFill != self.mentionFill
                || link != linkColor || text != themeText, let storage = textStorage
        else { return }
        self.fontSize = fontSize
        self.mentionText = mentionText
        self.mentionFill = mentionFill
        linkColor = link
        themeText = text
        storage.beginEditing()
        restyle(NSRange(location: 0, length: storage.length))
        storage.padMentionPills()
        storage.endEditing()
        typingAttributes = attributes(typingStyle, block: typingBlock)
    }

    private func attributes(
        _ style: MessageTextStyle, block: ComposerBlock?, mention: ComposerMention? = nil, link: URL? = nil
    ) -> [NSAttributedString.Key: Any] {
        let code = block == .code
        let monospaced = code || style.contains(.code)
        let size = monospaced ? max(10, fontSize - 1) : fontSize
        var font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        var traits = font.fontDescriptor.symbolicTraits
        if style.contains(.bold) && !code { traits.insert(.bold) }
        if style.contains(.italic) && !code { traits.insert(.italic) }
        font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
            .paragraphStyle: MessageBlocks.paragraph(
                quote: block == .quote, list: block == .bullet || block == .ordered ? 1 : 0, code: code,
                fontSize: fontSize, lineSpacing: 0),
        ]
        if !style.isEmpty { attributes[.composerStyle] = Int(style.rawValue) }
        if let block { attributes[.composerBlock] = block.rawValue }
        if block == .quote { attributes[.quoteBar] = themeText.withAlphaComponent(0.25) }
        if code {
            attributes[.codeBlock] = themeText.withAlphaComponent(0.04)
        } else {
            if style.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.contains(.code) { attributes[.backgroundColor] = themeText.withAlphaComponent(0.07) }
        }
        if let mention {
            attributes[.foregroundColor] = mentionText
            attributes[.mentionPill] = mentionFill
            attributes[.composerMention] = mention
        } else if let link {
            attributes[.foregroundColor] = linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.composerLink] = link
        }
        return attributes
    }

    private func style(_ attributes: [NSAttributedString.Key: Any]) -> MessageTextStyle {
        MessageTextStyle(rawValue: UInt8(attributes[.composerStyle] as? Int ?? 0))
    }

    private func block(_ attributes: [NSAttributedString.Key: Any]) -> ComposerBlock? {
        (attributes[.composerBlock] as? String).flatMap(ComposerBlock.init)
    }

    func block(at index: Int) -> ComposerBlock? {
        guard let storage = textStorage, index < storage.length else { return nil }
        return block(storage.attributes(at: index, effectiveRange: nil))
    }

    /// Recomputes how `range` looks from what it is. Callers bracket it with `beginEditing` when not processing.
    private func restyle(_ range: NSRange) {
        guard let storage = textStorage, range.length > 0 else { return }
        storage.enumerateAttributes(in: range) { current, part, _ in
            storage.setAttributes(
                attributes(
                    style(current), block: block(current), mention: current[.composerMention] as? ComposerMention,
                    link: current[.composerLink] as? URL), range: part)
        }
        // A neighbor's padding depends on whether this range is code too.
        let start = max(0, range.location - 1)
        MessageBlocks.padCodeBlocks(
            storage, in: NSRange(location: start, length: min(storage.length, NSMaxRange(range) + 1) - start),
            fontSize: fontSize)
    }

    /// A paragraph is one block: when an edit joins two, the first one's wins.
    func textStorage(
        _ storage: NSTextStorage, willProcessEditing mask: NSTextStorageEditActions, range: NSRange,
        changeInLength: Int
    ) {
        guard mask.contains(.editedCharacters) else { return }
        let text = storage.string as NSString
        let paragraphs = text.paragraphRange(for: range)
        text.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) {
            _, _, paragraph, _ in
            guard paragraph.length > 0 else { return }
            var uniform = NSRange()
            let block = storage.attribute(
                .composerBlock, at: paragraph.location, longestEffectiveRange: &uniform, in: paragraph)
            guard uniform != paragraph else { return }
            if let block {
                storage.addAttribute(.composerBlock, value: block, range: paragraph)
            } else {
                storage.removeAttribute(.composerBlock, range: paragraph)
            }
            self.restyle(paragraph)
        }
        let start = max(0, paragraphs.location - 1)
        MessageBlocks.padCodeBlocks(
            storage, in: NSRange(location: start, length: min(storage.length, NSMaxRange(paragraphs) + 1) - start),
            fontSize: fontSize)
        storage.padMentionPills()
    }

    // MARK: Typing

    private var typingStyle: MessageTextStyle { style(super.typingAttributes) }
    /// The caret's paragraph's block; an empty last line has no characters, so its block lives in typing attributes.
    var typingBlock: ComposerBlock? {
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        return paragraph.length > 0 ? block(at: paragraph.location) : block(super.typingAttributes)
    }

    /// Text typed next to a token or a link is plain text, and it joins the block of the paragraph it lands in.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { attributes(typingStyle, block: typingBlock) }
        set { super.typingAttributes = newValue }
    }

    func typing(mention: ComposerMention) -> [NSAttributedString.Key: Any] {
        attributes(typingStyle, block: typingBlock, mention: mention)
    }

    func publishFormats() {
        let range = selectedRange()
        var style = typingStyle
        if range.length > 0, let storage = textStorage {
            style = MessageTextStyle(rawValue: .max)
            storage.enumerateAttributes(in: range) { attributes, part, _ in
                if !(string as NSString).substring(with: part).allSatisfy(\.isNewline) {
                    style.formIntersection(self.style(attributes))
                }
            }
        }
        onFormatsChange?(ComposerFormats(style: style, block: typingBlock))
    }

    // MARK: Formatting commands

    /// Slack's toggle: on for the whole selection unless all of it has it already; at the caret, for what comes next.
    func toggle(_ style: MessageTextStyle) {
        let range = selectedRange()
        guard let storage = textStorage, range.length > 0 else {
            typingAttributes = attributes(typingStyle.symmetricDifference(style), block: typingBlock)
            publishFormats()
            return
        }
        var on = false
        storage.enumerateAttribute(.composerStyle, in: range) { value, part, _ in
            let current = MessageTextStyle(rawValue: UInt8(value as? Int ?? 0))
            if !current.contains(style) && !(string as NSString).substring(with: part).allSatisfy(\.isNewline) {
                on = true
            }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.composerStyle, in: range) { value, part, _ in
            var current = MessageTextStyle(rawValue: UInt8(value as? Int ?? 0))
            if on { current.insert(style) } else { current.remove(style) }
            storage.addAttribute(.composerStyle, value: Int(current.rawValue), range: part)
        }
        restyle(range)
        storage.endEditing()
        didChangeText()
        publishFormats()
    }

    /// Turns the selected paragraphs into `block`, or back into plain paragraphs when they all are already.
    func toggle(block: ComposerBlock) {
        guard let storage = textStorage else { return }
        let paragraphs = (string as NSString).paragraphRange(for: selectedRange())
        var all = true
        if paragraphs.length > 0 {
            storage.enumerateAttribute(.composerBlock, in: paragraphs) { value, _, _ in
                if value as? String != block.rawValue { all = false }
            }
        } else {
            all = typingBlock == block
        }
        let target = all ? nil : block
        if paragraphs.length > 0 {
            guard shouldChangeText(in: paragraphs, replacementString: nil) else { return }
            storage.beginEditing()
            if let target {
                storage.addAttribute(.composerBlock, value: target.rawValue, range: paragraphs)
            } else {
                storage.removeAttribute(.composerBlock, range: paragraphs)
            }
            restyle(paragraphs)
            storage.endEditing()
            didChangeText()
        }
        typingAttributes = attributes(typingStyle, block: target)
        if paragraphs.length == 0 {
            // An empty last line takes its indent from typing attributes, which layout doesn't watch.
            storage.edited(.editedAttributes, range: paragraphs, changeInLength: 0)
            needsDisplay = true
        }
        publishFormats()
    }

    func linkDraft() -> ComposerLinkDraft? {
        guard let storage = textStorage else { return nil }
        var range = selectedRange()
        var url: URL?
        let probe = range.length > 0 ? range.location : range.location - 1
        if probe >= 0, probe < storage.length {
            var link = NSRange()
            url =
                storage.attribute(
                    .composerLink, at: probe, longestEffectiveRange: &link,
                    in: NSRange(location: 0, length: storage.length)) as? URL
            if url != nil, range.length == 0 || NSIntersectionRange(link, range) == range { range = link }
        }
        return ComposerLinkDraft(
            range: range, text: (string as NSString).substring(with: range), url: url?.absoluteString ?? "")
    }

    /// Links `draft.text` to its address, or unlinks it when the address is empty.
    func setLink(_ draft: ComposerLinkDraft) {
        guard let storage = textStorage, NSMaxRange(draft.range) <= storage.length, draft.isValid else { return }
        let url = draft.link
        let text = draft.text.isEmpty ? url?.absoluteString ?? "" : draft.text
        let current =
            draft.range.length > 0
            ? storage.attributes(at: draft.range.location, effectiveRange: nil) : super.typingAttributes
        let linked = NSAttributedString(
            string: text, attributes: attributes(style(current), block: typingBlock, link: url))
        guard shouldChangeText(in: draft.range, replacementString: text) else { return }
        storage.replaceCharacters(in: draft.range, with: linked)
        didChangeText()
        setSelectedRange(NSRange(location: draft.range.location + linked.length, length: 0))
    }

    // MARK: Drafts

    private func attributed(_ paragraphs: [ComposerFormat.Paragraph]) -> NSMutableAttributedString {
        let text = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            for run in paragraph.runs {
                text.append(
                    NSAttributedString(
                        string: run.text,
                        attributes: attributes(
                            run.style, block: paragraph.block, mention: run.mention.map(ComposerMention.init),
                            link: run.mention == nil ? run.link : nil)))
            }
            if index < paragraphs.count - 1 {
                text.append(NSAttributedString(string: "\n", attributes: attributes([], block: paragraph.block)))
            }
        }
        MessageBlocks.padCodeBlocks(text, in: NSRange(location: 0, length: text.length), fontSize: fontSize)
        text.padMentionPills()
        return text
    }

    func load(_ draft: String, members: [ChatUser]) {
        let paragraphs = ComposerFormat.paragraphs(html: draft).map { paragraph in
            var named = paragraph
            named.runs = MessageBodyRenderer.named(paragraph.runs) { id in members.first { $0.id == id }?.name }
            return named
        }
        textStorage?.setAttributedString(attributed(paragraphs))
        // A cleared or switched draft starts plain, not in the list or quote the last one ended in.
        typingAttributes = attributes([], block: nil)
    }

    var draft: String {
        guard let storage = textStorage else { return "" }
        let text = storage.string as NSString
        var paragraphs: [ComposerFormat.Paragraph] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) {
            _, content, enclosing, _ in
            var paragraph = ComposerFormat.Paragraph(block: self.block(at: enclosing.location))
            storage.enumerateAttributes(in: content) { attributes, range, _ in
                let mention = attributes[.composerMention] as? ComposerMention
                paragraph.runs.append(
                    MessageBodyRun(
                        text: text.substring(with: range), style: self.style(attributes),
                        link: mention.flatMap { URL(string: MatrixID.permalink($0.userID)) }
                            ?? attributes[.composerLink] as? URL, mention: mention?.userID))
            }
            paragraphs.append(paragraph)
        }
        return ComposerFormat.html(paragraphs)
    }

    // MARK: Mention tokens: "@Name" that edits as one piece

    /// The token that `index` falls strictly inside.
    private func mention(cutAt index: Int) -> NSRange? {
        guard let storage = textStorage, index > 0, index < storage.length else { return nil }
        var token = NSRange()
        guard
            storage.attribute(
                .composerMention, at: index, longestEffectiveRange: &token,
                in: NSRange(location: 0, length: storage.length)) != nil, token.location < index
        else { return nil }
        return token
    }

    private func widened(_ range: NSRange) -> NSRange {
        [range.location, NSMaxRange(range)].compactMap(mention(cutAt:)).reduce(range, NSUnionRange)
    }

    /// The caret never stops inside a token: it jumps over it the way it was moving. A selection takes whole tokens.
    func outsideMentions(_ range: NSRange, from old: NSRange) -> NSRange {
        guard range.length == 0, let token = mention(cutAt: range.location) else { return widened(range) }
        return NSRange(location: old.location <= token.location ? NSMaxRange(token) : token.location, length: 0)
    }

    /// An edit that cuts into a token takes the whole token, so one Backspace deletes it.
    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        let whole = widened(range)
        guard whole != range, let replacementString else {
            return super.shouldChangeText(in: range, replacementString: replacementString)
        }
        insertText(replacementString, replacementRange: whole)
        return false
    }

    // MARK: Keys

    private var caretParagraphIsEmpty: Bool {
        let paragraph = (string as NSString).paragraphRange(for: selectedRange())
        return (string as NSString).substring(with: paragraph).allSatisfy(\.isNewline)
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        if onSpecialKey?(event) == true { return }
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) {
            // In a list, quote or code block, Return starts the next line of it, and on an empty line ends it.
            if let block = typingBlock {
                if caretParagraphIsEmpty { toggle(block: block) } else { insertNewline(nil) }
            } else {
                onSend?()
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Backspace at the start of a list item, quote or code line takes the block away before any text.
    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0, let block = typingBlock,
            range.location == (string as NSString).paragraphRange(for: range).location
        {
            toggle(block: block)
            return
        }
        super.deleteBackward(sender)
    }

    /// Slack's markup at the start of a line: "- ", "* ", "1. ", "> " and "```" become the block they stand for.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        let caret = selectedRange()
        let paragraph = (self.string as NSString).paragraphRange(for: caret)
        if let typed, typed == " " || typed == "`", !hasMarkedText(), replacementRange.location == NSNotFound,
            caret.length == 0, typingBlock == nil,
            case let marker = NSRange(location: paragraph.location, length: caret.location - paragraph.location),
            let block = Self.markup[(self.string as NSString).substring(with: marker) + typed]
        {
            breakUndoCoalescing()
            super.insertText("", replacementRange: marker)
            toggle(block: block)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }
    private static let markup: [String: ComposerBlock] = [
        "- ": .bullet, "* ": .bullet, "1. ": .ordered, "> ": .quote, "```": .code,
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        // The layout's own character, or the US one on a layout without Latin letters, as menus match shortcuts.
        let typed = event.characters(byApplyingModifiers: [])?.lowercased() ?? ""
        let key = !typed.isEmpty && typed.allSatisfy(\.isASCII) ? typed : Self.usKeys[event.keyCode] ?? ""
        switch (event.modifierFlags.intersection([.command, .shift, .option, .control]), key) {
        case ([.command], "b"): toggle(.bold)
        case ([.command], "i"): toggle(.italic)
        case ([.command, .shift], "x"): toggle(.strike)
        case ([.command, .shift], "c"): toggle(.code)
        case ([.command, .shift, .option], "c"): toggle(block: .code)
        case ([.command, .shift], "7"): toggle(block: .ordered)
        case ([.command, .shift], "8"): toggle(block: .bullet)
        case ([.command, .shift], "9"): toggle(block: .quote)
        case ([.command, .shift], "u"): onLink?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    private static let usKeys: [UInt16: String] = [
        11: "b", 34: "i", 7: "x", 8: "c", 32: "u", 26: "7", 28: "8", 25: "9",
    ]

    // MARK: Paste and drop

    /// HTML keeps what a message can carry; anything else arrives as plain text.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.html, .string] }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .html, let html = pboard.string(forType: .html) else {
            return super.readSelection(from: pboard, type: type)
        }
        // A page with markup a message can't carry pastes as the text its source app offers.
        if MessageBodyRenderer.editable(body: "", html: html).usedPlainTextFallback {
            return super.readSelection(from: pboard, type: .string)
        }
        var paragraphs = ComposerFormat.paragraphs(html: html)
        // The first line joins the paragraph it lands in.
        if !paragraphs.isEmpty, paragraphs[0].block == nil { paragraphs[0].block = typingBlock }
        let fragment = attributed(paragraphs)
        let range = rangeForUserTextChange
        guard range.location != NSNotFound, shouldChangeText(in: range, replacementString: fragment.string) else {
            return false
        }
        textStorage?.replaceCharacters(in: range, with: fragment)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + fragment.length, length: 0))
        return true
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), hasAttachment(.general) { return isEditable && acceptsAttachments }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if hasAttachment(.general) { _ = acceptAttachments(.general) } else { super.paste(sender) }
    }

    private func hasAttachment(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private func acceptAttachments(_ pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        guard let input = ComposerAttachmentInput(pasteboard: pasteboard) else {
            onAttachmentError?("Couldn’t paste the image. Attach it as a file instead.")
            return false
        }
        return onAttachments?(input) ?? false
    }
}

/// Draws list markers in the indent, where they can't be selected or typed into, and the block of an empty last
/// line, which has no characters to carry it.
private final class ComposerLayoutManager: PillLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let view = firstTextView as? ComposerTextView else { return }
        let text = storage.string as NSString
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        text.enumerateSubstrings(
            in: text.paragraphRange(for: characters), options: [.byParagraphs, .substringNotRequired]
        ) { _, _, paragraph, _ in
            guard paragraph.length > 0, let block = view.block(at: paragraph.location) else { return }
            let glyph = self.glyphIndexForCharacter(at: paragraph.location)
            let line = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            self.drawMarker(
                block, at: paragraph.location, view: view,
                origin: NSPoint(x: line.minX + origin.x, y: line.minY + self.location(forGlyphAt: glyph).y + origin.y))
        }
        guard extraLineFragmentTextContainer != nil, view.selectedRange().location == storage.length,
            let block = view.typingBlock
        else { return }
        let line = extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
        let attributes = view.typingAttributes
        let font = attributes[.font] as? NSFont
        switch block {
        case .bullet, .ordered:
            drawMarker(
                block, at: storage.length, view: view,
                origin: NSPoint(x: line.minX, y: line.minY + (font?.ascender ?? line.height)))
        case .quote, .code:
            let key: NSAttributedString.Key = block == .quote ? .quoteBar : .codeBlock
            guard let color = attributes[key] as? NSColor else { return }
            MessageBlocks.draw(
                key, color: color, lines: line, style: attributes[.paragraphStyle] as? NSParagraphStyle,
                fontSize: font?.pointSize ?? NSFont.systemFontSize)
        }
    }

    /// `baseline` is where the line's first glyph sits.
    private func drawMarker(_ block: ComposerBlock, at index: Int, view: ComposerTextView, origin baseline: NSPoint) {
        guard block == .bullet || block == .ordered, let storage = textStorage else { return }
        var number = 1
        if block == .ordered {
            let text = storage.string as NSString
            var start = index
            while start > 0 {
                let previous = text.paragraphRange(for: NSRange(location: start - 1, length: 0))
                guard view.block(at: previous.location) == .ordered else { break }
                number += 1
                start = previous.location
            }
        }
        let font = view.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
        let marker = NSAttributedString(
            string: block == .bullet ? "•" : "\(number).",
            attributes: [.font: NSFont.systemFont(ofSize: font.pointSize), .foregroundColor: NSColor.labelColor])
        // Where a message's marker text sits, so a list looks the same before and after sending.
        marker.draw(at: NSPoint(x: baseline.x, y: baseline.y - font.ascender))
    }
}

/// A staged attachment as Slack's composer shows it: an image as a square thumbnail, any other file as a tile with
/// its type, name and kind. Removing it takes the ✕ that shows in the corner on hover or keyboard focus.
private struct StagedAttachmentTile: View {
    private static let side: CGFloat = 62
    private static let fileWidth: CGFloat = 220
    @Environment(\.metrics) private var m
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var appearance: AppearanceStore
    let url: URL
    let onRemove: () -> Void
    @State private var thumbnail: CGImage?
    @State private var undecodable = false
    @State private var hovering = false
    @FocusState private var removeFocused: Bool
    private var attachment: MessageAttachment {
        MessageAttachment(name: url.lastPathComponent, url: url.absoluteString)
    }

    var body: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radiusLarge)
        Group {
            if attachment.fileKind == .image {
                shape.fill(colors.sunken)
                    .overlay {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFill().transition(.opacity)
                        } else if undecodable {
                            FileTypeIcon(kind: .image)
                        }
                    }
                    .frame(width: m(Self.side), height: m(Self.side)).clipShape(shape)
            } else {
                HStack(spacing: m.sp8) {
                    FileTypeIcon(kind: attachment.fileKind)
                    VStack(alignment: .leading, spacing: m.sp2) {
                        Text(attachment.name).font(m.font(.secondary, .semibold)).foregroundStyle(colors.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(attachment.typeLabel).font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, m.sp12).frame(width: m(Self.fileWidth), height: m(Self.side))
                .background(colors.canvas, in: shape)
            }
        }
        .overlay(shape.strokeBorder(colors.border))
        .help(attachment.name).accessibilityElement(children: .ignore).accessibilityLabel(attachment.name)
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark").font(m.font(.caption, .bold)).foregroundStyle(colors.onMedia)
                    .frame(width: m.sp20, height: m.sp20).background(colors.mediaControl, in: Circle())
            }
            .buttonStyle(.row).focused($removeFocused).help("Remove \(attachment.name)")
            .accessibilityLabel("Remove \(attachment.name)")
            .padding(m.sp4).opacity(hovering || removeFocused ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .task(id: url) { await decode() }
    }

    /// Off the main thread and at the tile's pixel size, never the full image.
    private func decode() async {
        guard attachment.fileKind == .image, thumbnail == nil else { return }
        let url = url
        let pixels = Int((m(Self.side) * displayScale).rounded(.up))
        let image = await Task.detached(priority: .userInitiated) {
            ComposerAttachmentImporter.thumbnail(of: url, pixels: pixels)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(Motion.content) {
            thumbnail = image
            undecodable = image == nil
        }
    }
}
