import AppKit
import SwiftUI

/// Who the mentions in a body name: the reader, whose pills are yellow, and the conversation's members, whose
/// display names replace bare IDs.
struct MentionContext: Equatable {
    var me: String?
    var members: [ChatUser] = []
}

private struct MentionContextKey: EnvironmentKey { static let defaultValue = MentionContext() }
extension EnvironmentValues {
    var mentions: MentionContext {
        get { self[MentionContextKey.self] }
        set { self[MentionContextKey.self] = newValue }
    }
}

struct NativeMessageBody: View {
    private var messageBody: String
    var formattedBody: String?
    /// Ends the text with Slack's inline "(edited)".
    private var edited: Bool
    private var showsSpoilerControl: Bool
    /// Off where a placeholder holds the row at text size until the body arrives, such as a Threads preview.
    private var largeEmoji: Bool
    private var role: TextRole
    private var textColor: Color?
    /// Compact mode's sender name, flowed inline before plain/inline text or stacked above block elements.
    private var senderName: String?
    private var onOpenSender: (() -> Void)?
    private var menuCommands: () -> [MessageMenuCommand]
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.metrics) private var m
    @Environment(\.openURL) private var openURL
    @Environment(\.mentions) private var mentions
    @State private var revealedSpoilerKey: SourceKey?

    private struct SourceKey: Hashable {
        var body: String
        var html: String?
    }
    init(
        body: String, formattedBody: String?, edited: Bool = false, showsSpoilerControl: Bool = true,
        largeEmoji: Bool = true, role: TextRole = .reading, textColor: Color? = nil, senderName: String? = nil,
        onOpenSender: (() -> Void)? = nil, menuCommands: @escaping () -> [MessageMenuCommand] = { [] }
    ) {
        messageBody = body
        self.formattedBody = formattedBody
        self.edited = edited
        self.showsSpoilerControl = showsSpoilerControl
        self.largeEmoji = largeEmoji
        self.role = role
        self.textColor = textColor
        self.senderName = senderName
        self.onOpenSender = onOpenSender
        self.menuCommands = menuCommands
    }

    static func canFlowInlineSender(_ rendered: RenderedMessageBody) -> Bool {
        guard !rendered.isJumbomoji, let first = rendered.runs.first else { return false }
        return first.block == MessageBlock() && !first.marker && !first.text.hasPrefix("\n")
    }

    private var source: SourceKey { SourceKey(body: messageBody, html: formattedBody) }

    var body: some View {
        let revealed = revealedSpoilerKey == source
        // Timelines render bodies as their items arrive, so this is a cache hit; anything else renders here, never as
        // literal text that is swapped for the formatted body a frame later.
        let rendered = MessageBodyRenderer.shared.render(
            body: messageBody, formattedBody: formattedBody, revealSpoilers: revealed)
        let colors = appearance.colors
        let flowSender = senderName != nil && Self.canFlowInlineSender(rendered)
        let fontSize = m.size(largeEmoji && rendered.isJumbomoji ? .largeTitle : role)
        VStack(alignment: .leading, spacing: m.sp2) {
            if let senderName, !flowSender {
                Button {
                    onOpenSender?()
                } label: {
                    Text(senderName).font(m.font(.reading, .semibold)).foregroundStyle(colors.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                }.buttonStyle(.row).disabled(onOpenSender == nil).linkCursor().help("View profile")
            }
            NativeSelectableMessageText(
                runs: MessageBodyRenderer.named(rendered.runs) { id in mentions.members.first { $0.id == id }?.name },
                fontSize: fontSize, textColor: NSColor(textColor ?? colors.textBody), linkColor: NSColor(colors.accent),
                mentions: MentionPalette(
                    me: mentions.me, text: NSColor(colors.mentionText), fill: NSColor(colors.mentionFill),
                    ownText: NSColor(colors.mentionYouText), ownFill: NSColor(colors.mentionYouFill)),
                senderPrefix: flowSender
                    ? senderName.map { InlineSenderPrefix(name: $0, color: NSColor(colors.textPrimary)) } : nil,
                onOpenSender: flowSender ? onOpenSender : nil,
                suffix: edited
                    ? NSAttributedString(
                        string: " (edited)",
                        attributes: [
                            .font: m.nsFont(.subheadline), .foregroundColor: NSColor(colors.textSecondary),
                        ]) : nil,
                menuCommands: menuCommands, onOpenURL: { openURL($0) })
            if showsSpoilerControl && rendered.containsSpoilers {
                Button(revealed ? "Hide spoilers" : "Show spoilers") {
                    revealedSpoilerKey = revealed ? nil : source
                }.buttonStyle(.textLink).font(m.font(.subheadline)).accessibilityLabel(
                    revealed ? "Hide message spoilers" : "Reveal message spoilers")
            }
        }
    }

}
