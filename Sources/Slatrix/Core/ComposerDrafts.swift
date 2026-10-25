import Observation

/// Unsent text by conversation and by thread. `addresses` changes only when a draft starts or empties, so the
/// sidebar's draft marks aren't redrawn with every keystroke; only the composer reads the text.
@Observable @MainActor final class ComposerDrafts {
    var conversations: [String: String] = [:] { didSet { updateAddresses() } }
    /// By `ThreadDraftAddress.id`.
    var threads: [String: String] = [:] { didSet { updateAddresses() } }
    private(set) var addresses = Set<AttachmentDraftAddress>()

    private func updateAddresses() {
        let next = Set(conversations.filter { !$0.value.isEmpty }.keys.map { AttachmentDraftAddress(roomID: $0) })
            .union(
                threads.filter { !$0.value.isEmpty }.keys.compactMap {
                    ThreadDraftAddress(id: $0).map {
                        AttachmentDraftAddress(roomID: $0.roomID, threadRootID: $0.rootID)
                    }
                })
        if next != addresses { addresses = next }
    }
}
