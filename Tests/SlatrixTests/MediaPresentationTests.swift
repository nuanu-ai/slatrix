import CoreGraphics
import Foundation
import Testing

@testable import Slatrix

struct MediaPresentationTests {
    private let bounds = CGSize(width: 480, height: 360)

    @Test(
        "An image's box keeps its aspect within the bounds and is never enlarged",
        arguments: [
            (1_600, 900, CGSize(width: 480, height: 270)),
            (900, 1_600, CGSize(width: 202.5, height: 360)),
            (4_000, 1_000, CGSize(width: 480, height: 120)),
            (40, 30, CGSize(width: 40, height: 30)),
        ] as [(UInt64, UInt64, CGSize)])
    func knownSize(width: UInt64, height: UInt64, box: CGSize) {
        #expect(MediaBox.fit(width: width, height: height, within: bounds) == box)
    }

    @Test("An image of unknown size reserves one fixed box inside the bounds")
    func unknownSize() {
        let box = MediaBox.fit(width: nil, height: nil, within: bounds)
        #expect(box.width > 0 && box.height > 0 && box.width <= bounds.width && box.height <= bounds.height)
        #expect(MediaBox.fit(width: 1_200, height: 0, within: bounds) == box)
        #expect(MediaBox.fit(width: nil, height: 800, within: bounds) == box)
    }

    private func message(_ id: String, kind: String, mime: String? = nil, redacted: Bool = false) -> ChatMessage {
        ChatMessage(
            id: id, roomID: "!r:example.org", senderID: "@a:example.org", senderName: "A", body: id,
            timestamp: Date(timeIntervalSince1970: 0), kind: kind, isRedacted: redacted,
            attachment: kind == "m.text"
                ? nil : MessageAttachment(name: id, url: "mxc://example.org/\(id)", mimeType: mime))
    }

    @Test("The viewer steps through images and videos in timeline order, skipping text, files and deleted media")
    func navigation() {
        let messages = [
            message("$text", kind: "m.text"), message("$a", kind: "m.image", mime: "image/png"),
            message("$pdf", kind: "m.file", mime: "application/pdf"), message("$b", kind: "m.video", mime: "video/mp4"),
            message("$gone", kind: "m.image", mime: "image/png", redacted: true),
            message("$c", kind: "m.image", mime: "image/gif"),
        ]
        func step(_ id: String, _ offset: Int) -> String? {
            MediaViewerNavigation.neighbor(of: id, by: offset, in: messages)?.eventID
        }
        #expect(step("$a", 1) == "$b")
        #expect(step("$b", 1) == "$c")
        #expect(step("$c", -1) == "$b")
        #expect(step("$a", -1) == nil)
        #expect(step("$c", 1) == nil)
        #expect(step("$pdf", 1) == nil)
    }
}
