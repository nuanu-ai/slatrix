import AppKit
import SwiftUI

struct MessageMenuCommand: Identifiable {
    let id: String
    let title: String
    var isEnabled: Bool
    var isDestructive: Bool
    var isSeparator: Bool
    var perform: () -> Void

    init(
        id: String, title: String = "", isEnabled: Bool = true, isDestructive: Bool = false, isSeparator: Bool = false,
        perform: @escaping () -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.isSeparator = isSeparator
        self.perform = perform
    }
}

struct NativeMessageMenuCommands: View {
    let commands: [MessageMenuCommand]

    var body: some View {
        ForEach(commands) { command in
            if command.isSeparator {
                Divider()
            } else {
                Button(command.title, role: command.isDestructive ? .destructive : nil, action: command.perform)
                    .disabled(!command.isEnabled)
            }
        }
    }
}

@MainActor final class NativeMessageMenuAction: NSObject {
    private let command: MessageMenuCommand
    init(_ command: MessageMenuCommand) { self.command = command }
    @objc func invoke(_ sender: Any?) { if command.isEnabled && !command.isSeparator { command.perform() } }
}

@MainActor enum NativeMessageMenu {
    static func make(commands: [MessageMenuCommand]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        for command in commands {
            if command.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let target = NativeMessageMenuAction(command)
            let item = NSMenuItem(
                title: command.title, action: #selector(NativeMessageMenuAction.invoke(_:)), keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(command.id)
            // NSMenuItem's target is weak; each item retains its own immutable action snapshot.
            item.representedObject = target
            item.isEnabled = command.isEnabled
            if command.isDestructive {
                item.attributedTitle = NSAttributedString(
                    string: command.title, attributes: [.foregroundColor: NSColor.systemRed])
            }
            menu.addItem(item)
        }
        return menu
    }
}
