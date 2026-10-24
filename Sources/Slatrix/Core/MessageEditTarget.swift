import Foundation

/// The UI surface where Edit was chosen is distinct from a message's thread
/// relation: a historical thread reply can be edited in the conversation pane.
struct MessageEditTarget: Identifiable {
    enum Surface: Equatable {
        case conversation
        case thread(rootID: String)
    }
    struct Context: Equatable {
        let sessionID: UUID
        let userID: String?
        let roomID: String?
        let timelineID: UUID
        let threadID: String?
        let readyThreadID: String?
    }
    let id = UUID()
    let message: ChatMessage
    let surface: Surface
    private let context: Context

    init?(message: ChatMessage, surface: Surface, context: Context) {
        guard message.supportsTextEditing, message.senderID == context.userID, message.roomID == context.roomID,
            message.eventID.hasPrefix("$"), !message.isRedacted, message.sendState == "sent"
        else { return nil }
        if case .thread(let rootID) = surface {
            guard context.threadID == rootID, context.readyThreadID == rootID,
                message.eventID == rootID || message.threadRootID == rootID
            else { return nil }
        }
        self.message = message
        self.surface = surface
        self.context = context
    }

    func isCurrent(_ current: MessageEditTarget?, in value: Context) -> Bool {
        guard current?.id == id, value.sessionID == context.sessionID,
            value.userID == message.senderID, value.roomID == message.roomID,
            value.timelineID == context.timelineID
        else { return false }
        if case .thread(let rootID) = surface {
            return value.threadID == rootID && value.readyThreadID == rootID
        }
        return true
    }

    @discardableResult
    func write(_ value: String, current: MessageEditTarget?, context: Context, text: inout String) -> Bool {
        guard isCurrent(current, in: context) else { return false }
        text = value
        return true
    }

    @discardableResult
    func finish(current: inout MessageEditTarget?, context: Context, text: inout String) -> Bool {
        guard isCurrent(current, in: context) else { return false }
        current = nil
        text = ""
        return true
    }
}
