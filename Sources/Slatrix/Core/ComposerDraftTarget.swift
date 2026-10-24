/// Captures which text a composer owns before its asynchronous send starts.
struct ComposerDraftTarget {
    let roomID: String
    let threadRootID: String?
    private let editID: String?
    private let editSenderID: String?

    init(roomID: String, threadRootID: String? = nil, editing: ChatMessage?) {
        self.roomID = roomID
        self.threadRootID = threadRootID
        let edit = editing.flatMap { $0.roomID == roomID && $0.threadRootID == threadRootID ? $0 : nil }
        editID = edit?.eventID
        editSenderID = edit?.senderID
    }

    func read(draft: String?, editText: String, editing: ChatMessage?) -> String {
        guard editID != nil else { return draft ?? "" }
        return matches(editing) ? editText : ""
    }

    /// Returns true only when the captured draft was changed and needs persistence.
    @discardableResult
    func write(_ value: String, editing: ChatMessage?, draft: inout String?, editText: inout String) -> Bool {
        if editID != nil {
            guard matches(editing) else { return false }
            editText = value
            return false
        }
        draft = value.isEmpty ? nil : value
        return true
    }

    private func matches(_ editing: ChatMessage?) -> Bool {
        guard let editing else { return false }
        return editing.eventID == editID && editing.roomID == roomID && editing.threadRootID == threadRootID
            && editing.senderID == editSenderID
    }
}
