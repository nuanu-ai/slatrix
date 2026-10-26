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
    private var showsSpoilerControl: Bool
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
        body: String, formattedBody: String?, showsSpoilerControl: Bool = true,
        menuCommands: @escaping () -> [MessageMenuCommand] = { [] }
    ) {
        messageBody = body
        self.formattedBody = formattedBody
        self.showsSpoilerControl = showsSpoilerControl
        self.menuCommands = menuCommands
    }

    private var source: SourceKey { SourceKey(body: messageBody, html: formattedBody) }

    var body: some View {
        let revealed = revealedSpoilerKey == source
        // Timelines render bodies as their items arrive, so this is a cache hit; anything else renders here, never as
        // literal text that is swapped for the formatted body a frame later.
        let rendered = MessageBodyRenderer.shared.render(
            body: messageBody, formattedBody: formattedBody, revealSpoilers: revealed)
        let colors = appearance.colors
        VStack(alignment: .leading, spacing: m.sp4) {
            NativeSelectableMessageText(
                runs: MessageBodyRenderer.named(rendered.runs) { id in mentions.members.first { $0.id == id }?.name },
                fontSize: m.size(.body), textColor: NSColor(colors.textBody), linkColor: NSColor(colors.accent),
                mentions: MentionPalette(
                    me: mentions.me, text: NSColor(colors.mentionText), fill: NSColor(colors.mentionFill),
                    ownText: NSColor(colors.mentionYouText), ownFill: NSColor(colors.mentionYouFill)),
                menuCommands: menuCommands, onOpenURL: { openURL($0) })
            if showsSpoilerControl && rendered.containsSpoilers {
                Button(revealed ? "Hide spoilers" : "Show spoilers") {
                    revealedSpoilerKey = revealed ? nil : source
                }.buttonStyle(.textLink).font(m.font(.caption)).accessibilityLabel(
                    revealed ? "Hide message spoilers" : "Reveal message spoilers")
            }
        }
    }

}
