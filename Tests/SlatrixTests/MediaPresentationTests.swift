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

    @Test("A long file name cut to fit never puts the ellipsis beside a dot, at any width")
    func fileNameCut() {
        let name = "harbor-web-release-4.2.0-rc.3-macos-universal-signed-notarized-with-debug-symbols-2026-11-18.zip"
        #expect(FileName.middleTruncated(name) { _ in true } == name)
        #expect(FileName.middleTruncated("ab.cdef.zip") { $0.count <= 6 } == "ab…zip")
        for room in 8..<name.count {
            let cut = FileName.middleTruncated(name) { $0.count <= room }
            #expect(cut.count <= room && cut.contains("…"), "\(room): \(cut)")
            #expect(!cut.contains(".…") && !cut.contains("…."), "\(room): \(cut)")
        }
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

    // capability: message.media-viewer
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

    @Test("Opened from Files, the viewer steps through the list's files in list order, documents included")
    @MainActor func filesOrder() {
        let list = [
            message("$new", kind: "m.image", mime: "image/png"), message("$link", kind: "m.text"),
            message("$pdf", kind: "m.file", mime: "application/pdf"),
            message("$old", kind: "m.video", mime: "video/mp4"),
        ]
        // The open conversation, in the other order; Files doesn't step through it.
        let timeline = Array(list.reversed())
        let viewer = MediaViewerState()
        viewer.open(list[2], files: list)
        viewer.step(1, in: timeline)
        #expect(viewer.message?.eventID == "$old")
        viewer.step(1, in: timeline)
        #expect(viewer.message?.eventID == "$old")
        viewer.step(-1, in: timeline)
        viewer.step(-1, in: timeline)
        #expect(viewer.message?.eventID == "$new")
    }

    @Test("Viewer upgrades an open pending local echo when its remote server event lands instead of closing")
    @MainActor func upgradesPendingLocalEchoOnSend() {
        var local = message("unique-1", kind: "m.image", mime: "image/png")
        local.timelineEventID = "tx-1"
        local.sendState = "sending"
        local.attachment = MessageAttachment(name: "photo.png", url: "file:///tmp/photo.png", mimeType: "image/png")

        let viewer = MediaViewerState()
        viewer.open(local, surface: .conversation)

        var remote = local
        remote.timelineEventID = "$remote-1"
        remote.sendState = "sent"
        remote.attachment = MessageAttachment(name: "photo.png", url: "mxc://example.org/photo", mimeType: "image/png")

        viewer.update(from: [remote])
        #expect(viewer.message?.eventID == "$remote-1")
        #expect(viewer.message?.sendState == "sent")
        #expect(viewer.message?.attachment?.url == "mxc://example.org/photo")
    }

    @Test("Viewer pending notice distinguishes failed media from still-sending media")
    @MainActor func pendingMediaNoticeCopy() {
        var failedVideo = message("tx-v", kind: "m.video", mime: "video/mp4")
        failedVideo.sendState = "failed"
        #expect(MediaViewerState.pendingNotice(for: failedVideo, hasCachedStill: false) == "Couldn’t send.")

        var failedFile = message("tx-f", kind: "m.file", mime: "application/pdf")
        failedFile.sendState = "failed"
        #expect(MediaViewerState.pendingNotice(for: failedFile, hasCachedStill: false) == "Couldn’t send.")

        var sendingVideo = failedVideo
        sendingVideo.sendState = "sending"
        #expect(MediaViewerState.pendingNotice(for: sendingVideo, hasCachedStill: false) == "Still sending…")

        var sendingFile = failedFile
        sendingFile.sendState = "sending"
        #expect(MediaViewerState.pendingNotice(for: sendingFile, hasCachedStill: false) == "Available once sent.")

        var sendingImage = message("tx-i", kind: "m.image", mime: "image/png")
        sendingImage.sendState = "sending"
        #expect(MediaViewerState.pendingNotice(for: sendingImage, hasCachedStill: true) == nil)
        #expect(MediaViewerState.pendingNotice(for: sendingImage, hasCachedStill: false) == "Still sending…")
    }
}
