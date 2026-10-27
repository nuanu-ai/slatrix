import AppKit
import Testing

@testable import Slatrix

/// A pane's drop target as AppKit drives it during a drag.
@MainActor
struct DropToUploadTests {
    @MainActor private final class Pane {
        let view = UploadDropView()
        var shown: [Bool] = []
        var staged: [ComposerAttachmentInput] = []
        init(composer accepts: Bool = true) {
            view.onTargeted = { [unowned self] in shown.append($0) }
            if accepts {
                view.intake = { [unowned self] in
                    staged.append($0)
                    return true
                }
            }
        }
    }

    @Test("A pane takes dragged files and images and leaves dragged text to the composer")
    func registeredTypes() {
        let types = Pane().view.registeredDraggedTypes
        #expect([.fileURL, .png, .tiff].allSatisfy(types.contains))
        #expect(!types.contains(.string))
    }

    @Test("Files dragged over a pane show its overlay and, dropped, go to its composer")
    func dropsFiles() throws {
        let scratch = try TemporaryDirectory()
        let file = try scratch.file("notes.txt")
        let pane = Pane()
        let drag = FakeDrag(files: [file])
        #expect(pane.view.draggingEntered(drag) == .copy)
        #expect(pane.shown == [true])
        #expect(pane.view.performDragOperation(drag))
        #expect(pane.shown.last == false)
        guard case .files(let urls) = try #require(pane.staged.first) else {
            Issue.record("Staged \(pane.staged) instead of the file")
            return
        }
        #expect(urls.map(\.standardizedFileURL) == [file.standardizedFileURL])
    }

    @Test("An image dragged from a browser, with no file behind it, goes to the composer as image data")
    func dropsImageData() throws {
        let scratch = try TemporaryDirectory()
        let png = try Data(contentsOf: try scratch.png("photo.png", width: 4, height: 4))
        let pane = Pane()
        #expect(pane.view.performDragOperation(FakeDrag(png: png)))
        guard case .image(let data, png: true) = try #require(pane.staged.first) else {
            Issue.record("Staged \(pane.staged) instead of the image")
            return
        }
        #expect(data == png)
    }

    @Test("A drag that leaves the pane takes its overlay with it")
    func exitHidesOverlay() throws {
        let pane = Pane()
        let scratch = try TemporaryDirectory()
        let drag = FakeDrag(files: [try scratch.file("notes.txt")])
        _ = pane.view.draggingEntered(drag)
        pane.view.draggingExited(drag)
        #expect(pane.shown == [true, false])
        #expect(pane.staged.isEmpty)
    }

    @Test("With no composer taking attachments, a pane refuses the drag and shows nothing")
    func refusesWithoutComposer() throws {
        let pane = Pane(composer: false)
        let scratch = try TemporaryDirectory()
        let drag = FakeDrag(files: [try scratch.file("notes.txt")])
        #expect(pane.view.draggingEntered(drag) == [])
        #expect(!pane.view.performDragOperation(drag))
        #expect(!pane.shown.contains(true))
    }
}
