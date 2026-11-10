import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// A timeline cell on its own in an offscreen window, as the table shows it.
@MainActor
struct TimelineCellTests {
    static let id = "@someone-with-a-long-name:a-homeserver-with-a-long-name.example.org"

    /// A row mentioning someone by ID, much shorter once their name is known.
    static func mentions(_ context: TimelineRowContext) -> TimelineRow {
        var message = ChatMessage(
            id: "$mentions", roomID: "!room:example.org", senderID: "@other:example.org", senderName: "Other",
            body: id, timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        message.formattedBody = Array(repeating: "<a href=\"https://matrix.to/#/\(id)\">\(id)</a>", count: 8)
            .joined(separator: " ")
        let entry = TimelineEntry(
            id: message.id,
            kind: .message(
                TimelineMessageEntry(
                    message: message, grouped: false, time: "10:00 AM", saved: false, pinned: false, canPin: false,
                    highlighted: false, sendBusy: false)))
        return TimelineRow(entry: entry, hovered: false, context: context)
    }

    @Test("A row whose content shrinks after it was measured reports its content's new height")
    func reportsShrinkingContent() async throws {
        let id = Self.id
        let matrix = MatrixService()
        let context = TimelineRowContext()
        context.matrix = matrix
        context.appearance = AppearanceStore()
        var reports: [CGFloat] = []
        context.onHeight = { _, height in reports.append(height) }
        let window = offscreenWindow(NSSize(width: 620, height: 600))
        defer { window.close() }
        let cell = TimelineCell(identifier: .init("cell"))
        cell.show(Self.mentions(context), commands: nil)
        let measured = ceil(cell.height(width: 620))
        cell.frame = NSRect(x: 0, y: 0, width: 620, height: measured)
        window.contentView = cell
        cell.layoutSubtreeIfNeeded()

        // Names land after the row was measured, as members do, and the long IDs give way to them.
        matrix.members = [ChatUser(id: id, name: "Sam")]
        let shrunk = { ceil(cell.height(width: 620)) }
        #expect(
            await eventually {
                cell.layoutSubtreeIfNeeded()
                return shrunk() < measured
            })
        #expect(
            await eventually {
                cell.layoutSubtreeIfNeeded()
                return reports.last.map { abs(ceil($0) - shrunk()) < 0.5 } ?? false
            }, "The table can only close the gap under the shorter text if the cell says how tall it now is")
    }

    @Test("A row measured ahead of display reports its height when names landed before it was shown")
    func reportsContentChangedBeforeDisplay() async throws {
        let matrix = MatrixService()
        let context = TimelineRowContext()
        context.matrix = matrix
        context.appearance = AppearanceStore()
        var reports: [CGFloat] = []
        context.onHeight = { _, height in reports.append(height) }
        // Built and measured off screen, as the table prepares the rows the reader is heading for.
        let cell = TimelineCell(identifier: .init("cell"))
        cell.show(Self.mentions(context), commands: nil)
        let measured = ceil(cell.height(width: 620))
        cell.frame = NSRect(x: 0, y: 0, width: 620, height: measured)
        matrix.members = [ChatUser(id: Self.id, name: "Sam")]

        let window = offscreenWindow(NSSize(width: 620, height: 600))
        defer { window.close() }
        window.contentView = cell
        let shrunk = { ceil(cell.height(width: 620)) }
        #expect(
            await eventually {
                cell.layoutSubtreeIfNeeded()
                return shrunk() < measured
            })
        #expect(
            await eventually {
                cell.layoutSubtreeIfNeeded()
                return reports.last.map { abs(ceil($0) - shrunk()) < 0.5 } ?? false
            }, "Shown at the height measured before the names, the row would keep a gap under its text")
    }
}
