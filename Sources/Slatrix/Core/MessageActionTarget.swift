import Foundation

/// An action belongs to the pane where the user chose it, not to the event's
/// thread relation. In particular, a thread root has no thread relation itself.
struct MessageActionTarget: Identifiable {
    typealias Surface = MessageEditTarget.Surface
    struct Context: Hashable {
        let sessionID: UUID
        let userID: String?
        let roomID: String?
        let timelineID: UUID
        let threadSelectionID: UUID
        let threadPresentationID: UUID
        let readyThreadID: String?
        let authenticated: Bool
        let joined: Bool
        let preview: Bool
    }
    let id = UUID()
    let message: ChatMessage
    let surface: Surface
    private let owner: Context

    init?(message: ChatMessage, surface: Surface, context: Context) {
        guard context.authenticated, context.joined, !context.preview, context.userID != nil,
            message.roomID == context.roomID, message.eventID.hasPrefix("$"),
            message.sendState == "sent", !message.isRedacted
        else { return nil }
        if case .thread(let rootID) = surface {
            guard context.readyThreadID == rootID,
                message.eventID == rootID || message.threadRootID == rootID
            else { return nil }
        }
        self.message = message
        self.surface = surface
        owner = context
    }

    struct ReplyPreviewIdentity: Hashable {
        let sessionID: UUID
        let userID: String?
        let roomID: String
        let timelineID: UUID
        let messageID: String
        let replyID: String
        let threadRootID: String?
        let threadSelectionID: UUID?
        let threadPresentationID: UUID?
    }
    // Do not use this action's per-render UUID as a SwiftUI task identity.
    var replyPreviewIdentity: ReplyPreviewIdentity? {
        guard let replyID = message.replyToID else { return nil }
        let rootID: String?
        switch surface {
        case .conversation: rootID = nil
        case .thread(let root): rootID = root
        }
        return ReplyPreviewIdentity(
            sessionID: owner.sessionID, userID: owner.userID, roomID: message.roomID,
            timelineID: owner.timelineID, messageID: message.eventID, replyID: replyID, threadRootID: rootID,
            threadSelectionID: rootID == nil ? nil : owner.threadSelectionID,
            threadPresentationID: rootID == nil ? nil : owner.threadPresentationID)
    }

    func isCurrent(in context: Context) -> Bool {
        guard context.authenticated, context.joined, !context.preview,
            context.sessionID == owner.sessionID, context.userID == owner.userID,
            context.roomID == message.roomID, context.timelineID == owner.timelineID
        else { return false }
        if case .thread(let rootID) = surface {
            return context.threadSelectionID == owner.threadSelectionID
                && context.threadPresentationID == owner.threadPresentationID && context.readyThreadID == rootID
        }
        return true
    }
}
