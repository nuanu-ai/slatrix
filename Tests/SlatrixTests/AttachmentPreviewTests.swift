import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
struct AttachmentPreviewTests {
    private let roomID = "!files:example.org"
    private let client: FakeClient
    private let service = MatrixService()

    init() {
        client = FakeClient(rooms: [FakeRoom(roomInfo(id: roomID))])
        service.configureMessageActionsForChecks(
            client: client, main: nil, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())
        service.selectedRoomID = roomID
    }
    private func show(_ event: EventTimelineItem) {
        service.projectMediaCaptionForChecks([FakeTimelineItem(event)], roomID: roomID, inThread: false)
    }

    @Test("Previewing an attachment again reuses the downloaded file")
    func reusesDownload() async throws {
        show(fileEvent("$file", source: try encryptedSource()))
        let message = try #require(service.messages.first)
        let first = try await service.prepareAttachmentPreview(message)
        let second = try await service.prepareAttachmentPreview(message)
        #expect(first.url == second.url && client.downloads == 1)
    }

    @Test(
        "A preview ends when its message is deleted or its file is replaced, even under the same URL",
        arguments: [nil, "AQAAAAAAAAAAAAAAAAAAAA"])
    func endsWhenMessageChanges(replacementKey: String?) async throws {
        show(fileEvent("$file", source: try encryptedSource()))
        let message = try #require(service.messages.first)
        let preview = try await service.prepareAttachmentPreview(message)
        #expect(preview.isCurrent)
        show(fileEvent("$file", source: try replacementKey.map { try encryptedSource(key: $0) }))
        #expect(!preview.isCurrent)
        if replacementKey != nil {
            let current = try #require(service.messages.first)
            _ = try await service.prepareAttachmentPreview(current)
            #expect(client.downloads == 2)
        }
    }
}
