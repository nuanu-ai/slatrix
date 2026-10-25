import AppKit
import SwiftUI

struct NativeMessageBody: View {
    private var messageBody: String
    var formattedBody: String?
    private var showsSpoilerControl: Bool
    private var menuCommands: () -> [MessageMenuCommand]
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.metrics) private var m
    @Environment(\.openURL) private var openURL
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
        VStack(alignment: .leading, spacing: m.sp4) {
            NativeSelectableMessageText(
                runs: rendered.runs, fontSize: m.size(.body), textColor: NSColor(appearance.colors.text),
                linkColor: NSColor(appearance.colors.accent), menuCommands: menuCommands, onOpenURL: { openURL($0) })
            if showsSpoilerControl && rendered.containsSpoilers {
                Button(revealed ? "Hide spoilers" : "Show spoilers") {
                    revealedSpoilerKey = revealed ? nil : source
                }.buttonStyle(.link).font(m.font(.caption)).accessibilityLabel(
                    revealed ? "Hide message spoilers" : "Reveal message spoilers")
            }
        }
    }

}
