/// Slack's plain-key conversation shortcuts: what Esc, ⇧Esc and ↑ do when nothing closer to the key wants it.
enum ConversationKeys {
    enum Key { case escape, up }
    enum Action: Equatable { case markRead, markAllRead, editLastMessage }

    /// `otherModifiers` is any of ⌘, ⌥ or ⌃: those keys are someone else's shortcut.
    static func action(_ key: Key, shift: Bool, otherModifiers: Bool, composerText: String?) -> Action? {
        guard !otherModifiers else { return nil }
        switch key {
        case .escape: return shift ? .markAllRead : .markRead
        // Only from an empty composer: with text, ↑ moves the caret.
        case .up: return !shift && composerText?.isEmpty == true ? .editLastMessage : nil
        }
    }

    /// The message ↑ edits: your newest one that has been sent and can still be edited as text.
    static func lastEditable(_ messages: [ChatMessage], userID: String?) -> ChatMessage? {
        guard let userID else { return nil }
        return messages.last {
            $0.senderID == userID && $0.sendState == "sent" && !$0.isRedacted && $0.supportsTextEditing
        }
    }
}
