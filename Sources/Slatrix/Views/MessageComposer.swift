import AppKit
import SwiftUI

struct MessageComposer: View {
    private static let attachmentNameWidth: CGFloat = 152
    private static let emojiCell: CGFloat = 32
    private static let emojiColumns = 8
    @Binding var text: String
    var placeholder: String
    var members: [ChatUser]
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
    @State private var showEmoji = false
    @State private var emojiQuery = ""
    @State private var mentionQuery: String?
    @State private var mentionRange: NSRange?
    @State private var mentionIndex = 0
    @State private var typingTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme
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
    private var panelColor: Color {
        colorScheme == .dark ? Color(red: 0.133, green: 0.145, blue: 0.161) : Color(nsColor: .textBackgroundColor)
    }
    private var muted: Color { Color(nsColor: .secondaryLabelColor) }
    private var mentionMatches: [ChatUser] {
        guard let query = mentionQuery else { return [] }
        return Array(
            members.filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(query)
            }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                HStack(spacing: m.sp8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3, height: m.sp16)
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
                if text.isEmpty {
                    Text(placeholder)
                        .font(m.font(.body)).foregroundStyle(muted)
                        .padding(.leading, m.sp12).padding(.top, m.sp8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerNativeEditor(
                    text: $text, state: editor, enabled: !sending,
                    acceptsAttachments: !sending && !isEditing && !preparingAttachments, onTextChange: changed,
                    onSelectionChange: updateMention, onSend: send, onSpecialKey: specialKey,
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
                }.buttonStyle(ComposerToolStyle()).help(showFormatting ? "Hide formatting" : "Show formatting")
                    .accessibilityLabel(showFormatting ? "Hide formatting" : "Show formatting")
                iconButton("face.smiling", label: "Emoji") { showEmoji.toggle() }
                    .popover(isPresented: $showEmoji, arrowEdge: .bottom) { emojiPicker }
                iconButton("at", label: "Mention someone") {
                    editor.insert("@")
                    editor.focus()
                }.disabled(members.isEmpty)
                Spacer(minLength: m.sp4)
                if sending || preparingAttachments {
                    ProgressView().controlSize(.small).accessibilityLabel(
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
                        Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: m.sp16)
                        Text(isEditing ? "Save" : "↵").font(m.font(.meta, .medium))
                    }.foregroundStyle(canSend ? .white : muted)
                        .padding(.horizontal, m.sp12).frame(height: m.row)
                        .background(
                            canSend ? Color(red: 0, green: 0.48, blue: 0.35) : muted.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: m.radiusSmall)
                        )
                        .contentShape(Rectangle())
                }.buttonStyle(.row).disabled(!canSend)
                    .help(isEditing ? "Save changes (Return)" : "Send message (Return)")
                    .accessibilityLabel(isEditing ? "Save changes" : "Send message")
            }.padding(.horizontal, m.sp12).padding(.bottom, m.sp8).disabled(sending)
        }
        .background(panelColor, in: RoundedRectangle(cornerRadius: m.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: m.radiusLarge).strokeBorder(
                editor.isFocused ? muted.opacity(0.85) : muted.opacity(0.45), lineWidth: 1)
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
            if mentionQuery != nil {
                mentionQuery = nil
                mentionRange = nil
            } else if showEmoji {
                showEmoji = false
            } else if isEditing {
                onCancelEdit?()
            }
        }
    }

    private var floating: some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            if !mentionMatches.isEmpty { mentionSuggestions }
            Group {
                if let errorMessage {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                        Text(errorMessage).textSelection(.enabled)
                        Spacer(minLength: m.sp4)
                        Button("Try again", action: send).buttonStyle(.link).disabled(!canSend)
                    }.font(m.font(.meta)).foregroundStyle(Color(nsColor: .systemRed))
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
                    }.font(m.font(.meta)).foregroundStyle(Color(nsColor: .systemRed)).accessibilityElement(
                        children: .combine)
                }
                if requiresTextForSend && !attachments.isEmpty {
                    Text("Add a message to reply").font(m.font(.caption)).foregroundStyle(muted)
                }
            }
            .padding(.horizontal, m.sp12).padding(.vertical, m.sp8)
            .background(panelColor, in: RoundedRectangle(cornerRadius: m.radiusLarge))
        }
    }

    private var formattingToolbar: some View {
        HStack(spacing: 0) {
            formatButton("bold", label: "Bold (⌘B)") { editor.wrap("**") }
            formatButton("italic", label: "Italic (⌘I)") { editor.wrap("_") }
            formatButton("strikethrough", label: "Strikethrough") { editor.wrap("~~") }
            toolbarDivider
            formatButton("link", label: "Insert link") { editor.link() }
            toolbarDivider
            formatButton("list.bullet", label: "Bulleted list") { editor.prefixLines("- ") }
            formatButton("list.number", label: "Numbered list") { editor.prefixLines("1. ") }
            toolbarDivider
            formatButton("text.quote", label: "Quote") { editor.prefixLines("> ") }
            formatButton("chevron.left.forwardslash.chevron.right", label: "Inline code") { editor.wrap("`") }
            Spacer(minLength: 0)
        }.padding(.horizontal, m.sp8).padding(.top, m.sp8).disabled(sending)
            .accessibilityElement(children: .contain).accessibilityLabel("Message formatting")
    }

    private var toolbarDivider: some View {
        Rectangle().fill(muted.opacity(0.25)).frame(width: 1, height: m.sp16).padding(.horizontal, m.sp4)
    }

    private func formatButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(m.font(.secondary)).frame(width: m.iconButton, height: m.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(ComposerToolStyle()).help(label).accessibilityLabel(label)
    }

    private func iconButton(_ icon: String, label: String, circular: Bool = false, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: icon).font(m.font(.body)).frame(width: m.iconButton, height: m.iconButton)
                .background(circular ? muted.opacity(0.12) : Color.clear, in: Circle()).contentShape(Rectangle())
        }.buttonStyle(ComposerToolStyle()).help(label).accessibilityLabel(label)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: m.sp8) {
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: m.sp8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(
                            width: m.control, height: m.control)
                        VStack(alignment: .leading, spacing: m.sp4) {
                            Text(url.lastPathComponent).font(m.font(.meta, .medium)).lineLimit(1)
                            Text(
                                sending
                                    ? "Sending…" : url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
                            )
                            .font(m.font(.caption)).foregroundStyle(muted)
                        }.frame(maxWidth: m(Self.attachmentNameWidth), alignment: .leading)
                        Button {
                            attachments.removeAll { $0 == url }
                            discardAttachments([url])
                        } label: {
                            Image(systemName: "xmark").font(m.font(.caption, .semibold))
                        }
                        .buttonStyle(.row).disabled(sending || preparingAttachments).help(
                            "Remove \(url.lastPathComponent)"
                        )
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }.padding(m.sp8).background(muted.opacity(0.06), in: RoundedRectangle(cornerRadius: m.radius))
                        .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(muted.opacity(0.25)))
                }
            }.padding(.horizontal, m.sp12)
        }.scrollIndicators(.hidden).padding(.bottom, m.sp8)
    }

    private var mentionSuggestions: some View {
        VStack(alignment: .leading, spacing: m.sp2) {
            ForEach(Array(mentionMatches.enumerated()), id: \.element.id) { index, member in
                Button {
                    chooseMention(member)
                } label: {
                    HStack(spacing: m.sp8) {
                        Text(String(member.name.prefix(1)).uppercased()).font(m.font(.secondary, .semibold))
                            .frame(width: m.iconButton, height: m.iconButton).background(
                                Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: m.radius))
                        Text(member.name).font(m.font(.secondary, .medium))
                        // The ID tells apart people who share a name; otherwise it is noise.
                        if mentionMatches.filter({ $0.name == member.name }).count > 1 {
                            Text(member.id).font(m.font(.caption)).foregroundStyle(
                                index == mentionIndex ? Color.white.opacity(0.8) : muted
                            ).lineLimit(1)
                        }
                        Spacer()
                        if index == mentionIndex { Image(systemName: "return").font(m.font(.caption)) }
                    }.padding(.horizontal, m.sp12).padding(.vertical, m.sp8).contentShape(Rectangle())
                        .background(index == mentionIndex ? Color.accentColor : .clear)
                        .foregroundStyle(index == mentionIndex ? Color.white : Color(nsColor: .labelColor))
                }.buttonStyle(.row).accessibilityLabel("Mention \(member.name), \(member.id)")
            }
        }.padding(.vertical, m.sp4).background(panelColor, in: RoundedRectangle(cornerRadius: m.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(muted.opacity(0.4)))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            TextField("Search emoji", text: $emojiQuery).textFieldStyle(.roundedBorder).accessibilityLabel(
                "Search emoji"
            )
            .onSubmit {
                if let emoji = Self.emojis.first(where: {
                    emojiQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(emojiQuery)
                }) {
                    editor.insert(emoji.symbol)
                    showEmoji = false
                    emojiQuery = ""
                    editor.focus()
                }
            }
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(m(Self.emojiCell)), spacing: m.sp4), count: Self.emojiColumns),
                    spacing: m.sp4
                ) {
                    ForEach(
                        Self.emojis.filter {
                            emojiQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(emojiQuery)
                        }, id: \.symbol
                    ) { emoji in
                        Button {
                            editor.insert(emoji.symbol)
                            showEmoji = false
                            emojiQuery = ""
                            editor.focus()
                        } label: {
                            Text(emoji.symbol).font(m.font(.header)).frame(
                                width: m(Self.emojiCell), height: m(Self.emojiCell)
                            ).contentShape(
                                Rectangle())
                        }.buttonStyle(ComposerToolStyle()).help(emoji.name).accessibilityLabel(emoji.name)
                    }
                }
            }.frame(height: (m(Self.emojiCell) + m.sp4) * 6)
        }.padding(m.sp16).frame(
            width: m(Self.emojiCell) * CGFloat(Self.emojiColumns) + m.sp4 * CGFloat(Self.emojiColumns - 1) + m.sp16 * 2)
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
        if let match = prefix.range(of: #"(?:^|\s)@[^\s@]*$"#, options: .regularExpression),
            let at = prefix[match].lastIndex(of: "@")
        {
            mentionQuery = String(prefix[prefix.index(after: at)...])
            let location = prefix.utf16.distance(from: prefix.utf16.startIndex, to: at.samePosition(in: prefix.utf16)!)
            mentionRange = NSRange(location: location, length: (prefix as NSString).length - location)
            mentionIndex = 0
        } else {
            mentionQuery = nil
            mentionRange = nil
        }
    }

    private func specialKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            if mentionQuery != nil {
                mentionQuery = nil
                mentionRange = nil
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

    private func chooseMention(_ member: ChatUser) {
        editor.insert(member.id + " ", replacing: mentionRange)
        mentionQuery = nil
        mentionRange = nil
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
        mentionQuery = nil
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

    private static let emojis: [(symbol: String, name: String)] = [
        ("😀", "grinning happy"), ("😄", "smile happy"), ("😁", "grin"), ("😅", "sweat smile"), ("😂", "laughing joy"),
        ("🤣", "laughing rofl"), ("😊", "blush smile"), ("😉", "wink"),
        ("😍", "love heart eyes"), ("🥰", "love hearts"), ("😎", "cool sunglasses"), ("🤔", "thinking"), ("🫡", "salute"),
        ("🫠", "melting"), ("😭", "cry sad"), ("🤯", "mind blown"),
        ("👍", "thumbs up yes"), ("👎", "thumbs down no"), ("👏", "clap applause"), ("🙌", "hooray raised hands"),
        ("👋", "hello wave"), ("🙏", "thanks please"), ("💪", "strong muscle"), ("🤝", "handshake"),
        ("❤️", "heart love"), ("💜", "purple heart"), ("💚", "green heart"), ("🫶", "heart hands"), ("🔥", "fire"),
        ("✨", "sparkles"), ("🎉", "party celebrate"), ("🎊", "confetti"),
        ("🚀", "rocket launch"), ("✅", "done check"), ("👀", "eyes looking"), ("💯", "hundred perfect"), ("💡", "idea"),
        ("⭐", "star"), ("🏆", "trophy winner"), ("🎯", "target goal"),
        ("☕", "coffee"), ("🍵", "tea"), ("🍕", "pizza"), ("🍰", "cake"), ("🌴", "palm bali"), ("🌊", "ocean wave"),
        ("🌞", "sun"), ("🌱", "growth seedling"),
    ]
}

private struct ComposerToolStyle: ButtonStyle {
    @Environment(\.metrics) private var m
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .background(
                Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.16 : hovered ? 0.09 : 0),
                in: RoundedRectangle(cornerRadius: m.radiusSmall)
            )
            .onHover { hovered = $0 }
    }
}

@MainActor private final class ComposerEditorState: ObservableObject {
    @Published var isFocused = false
    weak var textView: ComposerTextView?

    func focus() { if let textView { textView.window?.makeFirstResponder(textView) } }

    func insert(_ string: String, replacing range: NSRange? = nil, selection: NSRange? = nil) {
        guard let textView, textView.isEditable else { return }
        let selected = range ?? textView.selectedRange()
        textView.insertText(string, replacementRange: selected)
        if let selection { textView.setSelectedRange(selection) }
        focus()
    }

    func wrap(_ marker: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let content = selected.isEmpty ? "text" : selected
        insert(
            marker + content + marker,
            selection: NSRange(
                location: range.location + (marker as NSString).length, length: (content as NSString).length))
    }

    func link() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let title = selected.isEmpty ? "link text" : selected
        insert(
            "[\(title)](https://)",
            selection: NSRange(location: range.location + (title as NSString).length + 3, length: 8))
    }

    func prefixLines(_ prefix: String) {
        guard let textView else { return }
        let text = textView.string as NSString
        var range = textView.selectedRange()
        if range.length > 0 && text.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n" {
            range.length -= 1
        }
        let lines = text.lineRange(for: range)
        var content = text.substring(with: lines)
        let trailingNewline = content.hasSuffix("\n")
        if trailingNewline { content.removeLast() }
        let result =
            content.components(separatedBy: "\n").enumerated().map { index, line in
                (prefix == "1. " ? "\(index + 1). " : prefix) + line
            }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        insert(
            result, replacing: lines, selection: NSRange(location: lines.location, length: (result as NSString).length))
    }
}

private struct ComposerNativeEditor: NSViewRepresentable {
    static let minHeight: CGFloat = 60
    static let maxHeight: CGFloat = 160
    @Binding var text: String
    var state: ComposerEditorState
    var enabled: Bool
    var acceptsAttachments: Bool
    var onTextChange: (String, NSRange) -> Void
    var onSelectionChange: (String, NSRange) -> Void
    var onSend: () -> Void
    var onSpecialKey: (NSEvent) -> Bool
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
        let view = ComposerTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.delegate = context.coordinator
        view.registerForDraggedTypes(view.registeredDraggedTypes + [.fileURL, .png, .tiff])
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
        if view.string != text {
            context.coordinator.synchronizing = true
            let previous = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(previous.location, (text as NSString).length), length: 0))
            context.coordinator.synchronizing = false
        }
        view.isEditable = enabled
    }

    private func configure(_ view: ComposerTextView, context: Context) {
        let m = context.environment.metrics
        if view.font?.pointSize != m.size(.body) {
            view.font = m.nsFont(.body)
            view.textContainerInset = NSSize(width: m.sp12, height: m.sp8)
        }
        view.onSend = onSend
        view.onSpecialKey = onSpecialKey
        view.acceptsAttachments = acceptsAttachments
        view.onAttachments = onAttachments
        view.onAttachmentError = onAttachmentError
        view.onBold = { state.wrap("**") }
        view.onItalic = { state.wrap("_") }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerNativeEditor
        var synchronizing = false
        init(_ parent: ComposerNativeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerTextView else { return }
            parent.text = view.string
            parent.onTextChange(view.string, view.selectedRange())
        }
        func textDidBeginEditing(_ notification: Notification) { parent.state.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.state.isFocused = false }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !synchronizing else { return }
            guard let view = notification.object as? ComposerTextView else { return }
            parent.onSelectionChange(view.string, view.selectedRange())
        }
    }
}

private final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onSpecialKey: ((NSEvent) -> Bool)?
    var acceptsAttachments = true
    var onAttachments: ((ComposerAttachmentInput) -> Bool)?
    var onAttachmentError: ((String) -> Void)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        if onSpecialKey?(event) == true { return }
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            if event.charactersIgnoringModifiers == "b" {
                onBold?()
                return true
            }
            if event.charactersIgnoringModifiers == "i" {
                onItalic?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), hasAttachment(.general) { return isEditable && acceptsAttachments }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if hasAttachment(.general) { _ = acceptAttachments(.general) } else { super.paste(sender) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasAttachment(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        return isEditable && acceptsAttachments ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard hasAttachment(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        return acceptAttachments(sender.draggingPasteboard)
    }

    private func hasAttachment(_ pasteboard: NSPasteboard) -> Bool {
        !fileURLs(from: pasteboard).isEmpty || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private func acceptAttachments(_ pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty { return onAttachments?(.files(urls)) ?? false }
        if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
            return onAttachments?(.image(data, png: type == .png)) ?? false
        }
        onAttachmentError?("Couldn’t paste the image. Attach it as a file instead.")
        return false
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard pasteboard.types?.contains(.fileURL) == true else { return [] }
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
            ?? []
    }
}
