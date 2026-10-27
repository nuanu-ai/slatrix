import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// Dragging files onto the open conversation in the whole window; opt-in like the other hosted tests.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct DropToUploadHostedTests {
    private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private func center(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.visibleRect.midX, y: view.visibleRect.midY), to: nil)
    }

    @Test("Files dragged over the conversation's messages, header or composer land on one drop target")
    func conversationTakesDrops() async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let hosting = NSHostingView(rootView: AnyView(RootView(matrix: matrix).environmentObject(AppearanceStore())))
        let window = offscreenWindow(NSSize(width: 1_200, height: 800))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        // Until the composer takes input: before then the conversation takes no drops either.
        var composer: NSTextView?
        #expect(
            await eventually(timeout: .seconds(10)) {
                hosting.layoutSubtreeIfNeeded()
                composer = Self.views(in: hosting).compactMap { $0 as? NSTextView }.first { $0.isEditable }
                return composer.map { hosting.hitTest(hosting.superview!.convert(center(of: $0), from: nil)) === $0 }
                    ?? false
            })
        let messages = try #require(
            Self.views(in: hosting).first { $0 is TimelineTableView }?.enclosingScrollView)
        let header = NSPoint(
            x: center(of: messages).x, y: messages.convert(messages.bounds, to: nil).maxY + Metrics().paneHeader / 2)

        let points = [center(of: try #require(composer)), center(of: messages), header]
        let targets = try points.map { try #require(try dropTarget(in: window, at: $0, types: [.fileURL]), "\($0)") }
        #expect(targets.allSatisfy { $0 === targets[0] })
        // An image from a browser or Photos, with no file behind it.
        #expect(try points.allSatisfy { try dropTarget(in: window, at: $0, types: [.png]) === targets[0] })
        // It spans the conversation, so it must not turn it into a handle that moves the window.
        #expect(!targets[0].mouseDownCanMoveWindow)
    }

    private final class Tray { var files: [URL] = [] }

    /// A composer in a pane that takes drops, and the pane's drop target.
    private func pane(editing: Bool = false, tray: Tray) throws -> (NSWindow, UploadDropView) {
        let hosting = NSHostingView(
            rootView: MessageComposer(
                text: .constant(""), placeholder: "Message #team", members: [], isEditing: editing,
                onSend: { _, _ in }, onTyping: { _ in },
                queuedFiles: Binding(get: { tray.files }, set: { tray.files = $0 })
            )
            .frame(width: 360, height: 300).dropToUpload("Upload to #team").environmentObject(AppearanceStore()))
        let window = offscreenWindow(NSSize(width: 400, height: 400))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let target = try #require(Self.views(in: hosting).compactMap { $0 as? UploadDropView }.first)
        return (window, target)
    }

    @Test("Files dropped on a pane are staged in its composer's tray, as the + button stages them")
    func dropStagesInTray() async throws {
        let scratch = try TemporaryDirectory()
        let file = try scratch.file("notes.txt")
        let tray = Tray()
        let (window, target) = try pane(tray: tray)
        defer {
            ComposerAttachmentImporter.discard(tray.files)
            window.contentView = nil
            window.close()
        }
        let drag = FakeDrag(files: [file], over: window)
        #expect(target.draggingEntered(drag) == .copy)
        #expect(target.performDragOperation(drag))
        #expect(await eventually { tray.files.count == 1 })
        // A private copy, so changing the original before sending changes nothing.
        #expect(tray.files.first?.standardizedFileURL != file.standardizedFileURL)
        #expect(tray.files.first.flatMap { try? Data(contentsOf: $0) } == (try Data(contentsOf: file)))
    }

    @Test("While a message is being edited, its pane refuses dropped files")
    func editingRefusesDrops() throws {
        let scratch = try TemporaryDirectory()
        let (window, target) = try pane(editing: true, tray: Tray())
        defer {
            window.contentView = nil
            window.close()
        }
        let drag = FakeDrag(files: [try scratch.file("notes.txt")], over: window)
        #expect(target.draggingEntered(drag) == [])
        #expect(!target.performDragOperation(drag))
    }
}
