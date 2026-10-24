import Foundation

struct MessageReplyTarget: Identifiable {
    enum Surface: Equatable {
        case conversation
        case thread(rootID: String)
    }
    struct Owner: Equatable {
        let userID: String?
        let sessionID: UUID
    }
    let id = UUID()
    let message: ChatMessage
    let surface: Surface
    let owner: Owner

    init?(message: ChatMessage, surface: Surface, owner: Owner) {
        guard owner.userID != nil, message.eventID.hasPrefix("$"), !message.isRedacted,
            message.sendState == "sent"
        else { return nil }
        switch surface {
        case .conversation:
            // SDK sendReply forwards a quoted event's thread relation. Reflect
            // that destination explicitly instead of promising a room reply.
            self.surface = message.threadRootID.map { .thread(rootID: $0) } ?? .conversation
        case .thread(let rootID):
            guard message.eventID == rootID || message.threadRootID == rootID else { return nil }
            self.surface = surface
        }
        self.message = message
        self.owner = owner
    }

    var threadID: String? {
        if case .thread(let rootID) = surface { return rootID }
        return nil
    }
    func belongsTo(roomID: String, threadID: String?) -> Bool { message.roomID == roomID && self.threadID == threadID }
    func isCurrent(_ current: MessageReplyTarget?, owner: Owner) -> Bool { current?.id == id && self.owner == owner }

    /// Captured nil is significant too: a newly chosen quote cannot silently
    /// change a send that was queued by an earlier render of this composer.
    static func authorizes(
        _ captured: MessageReplyTarget?, current: MessageReplyTarget?, owner: Owner, roomID: String, threadID: String?
    ) -> Bool {
        let scoped = current.flatMap { $0.belongsTo(roomID: roomID, threadID: threadID) ? $0 : nil }
        guard let captured else { return scoped == nil }
        return captured.belongsTo(roomID: roomID, threadID: threadID) && captured.isCurrent(scoped, owner: owner)
    }

    @discardableResult
    func finish(current: inout MessageReplyTarget?, owner: Owner) -> Bool {
        guard isCurrent(current, owner: owner) else { return false }
        current = nil
        return true
    }
}
