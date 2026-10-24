import Foundation

@MainActor
enum ThreadRootResolver {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "The original thread message is unavailable. Your draft and files have been kept."
        }
    }

    /// `validate` throws CancellationError when the original account,
    /// navigation or room context is no longer current.
    static func resolve(
        roomID: String, rootID: String, candidates: [ChatMessage],
        load: @MainActor (String, String) async throws -> ChatMessage,
        validate: @MainActor () throws -> Void
    ) async throws -> ChatMessage {
        @MainActor func checkContext() throws {
            try Task.checkCancellation()
            try validate()
        }
        try checkContext()
        guard !roomID.isEmpty, rootID.hasPrefix("$"), rootID.count > 1 else { throw Failure.unavailable }
        do {
            let root: ChatMessage
            if let cached = candidates.first(where: { $0.roomID == roomID && $0.eventID == rootID }) {
                root = cached
            } else {
                root = try await load(roomID, rootID)
            }
            try checkContext()
            guard root.roomID == roomID, root.eventID == rootID, root.threadRootID == nil,
                root.sendState == "sent"
            else { throw Failure.unavailable }
            // SDK mapping supports redacted originals. Their replies can still
            // be viewed; quoted-reply preparation keeps its own stricter policy.
            return root
        } catch {
            try checkContext()
            throw error
        }
    }
}
