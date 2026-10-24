import Foundation

// Disposable local samples are kept separate from the Matrix session and never sent to a server.
@MainActor extension MatrixService {
    func enterPreview() {
        guard canChangeAuthentication else { return }
        isPreview = true
        status = .ready
        user = ChatUser(id: "preview.you", name: "You")
        workspaces = [
            Workspace(id: "preview.workspace", name: "Harbor"), Workspace(id: "preview.studio", name: "Studio"),
        ]
        rooms = [
            "Team", "Welcome", "Design", "Engineering", "Platform and Tools", "Planning and Demos",
            "Marketing and Growth", "Support", "Random",
        ].enumerated().map { index, name in
            ChatRoom(
                id: "preview.room.\(index)", name: name,
                topic: index == 0
                    ? "A place for the team. Share ideas, ask questions, and keep things moving."
                    : "Everything about \(name.lowercased()).", unread: index == 2 ? 3 : 0, favorite: index == 0,
                memberCount: 4, spaceIDs: ["preview.workspace"])
        }
        rooms += ["Brand", "Launch"].enumerated().map { index, name in
            ChatRoom(
                id: "preview.studio.\(index)", name: name, topic: "Everything about \(name.lowercased()).",
                unreadMessages: 4, mentions: index, memberCount: 3, spaceIDs: ["preview.studio"])
        }
        rooms.append(
            contentsOf: ["Alex", "Julia", "Sam"].enumerated().map { index, name in
                ChatRoom(id: "preview.dm.\(index)", name: name, isDirect: true, isEncrypted: true, memberCount: 2)
            })
        members = [
            ChatUser(id: "preview.alex", name: "Alex"),
            ChatUser(id: "preview.julia", name: "Julia"), ChatUser(id: "preview.sam", name: "Sam"),
            user!,
        ]
        selectPreviewRoom(rooms[0].id)
    }
    func selectPreviewRoom(_ id: String) {
        selectedRoomID = id
        let now = Date()
        func sample(
            _ id: String, _ sender: Int, _ body: String, html: String? = nil, _ minutes: Double, replies: Int = 0,
            reactions: [MessageReaction] = []
        ) -> ChatMessage {
            // Real clients send Markdown as HTML with a plain-text fallback; samples do the same.
            ChatMessage(
                id: id, roomID: self.selectedRoomID!, senderID: members[sender].id, senderName: members[sender].name,
                body: body, formattedBody: html, timestamp: now.addingTimeInterval(-minutes * 60),
                reactions: reactions, replyCount: replies)
        }
        messages = [
            sample(
                "preview.welcome", 0,
                "Welcome to our new workspace 👋\n\nOne place for our conversations, projects, and ideas. Pick a channel on the left to get started.",
                180, reactions: [.init(key: "👋", count: 3, mine: false)]),
            sample(
                "preview.plan", 1,
                "A little structure for the week:\n\n• #team — updates and everyday conversations\n• #planning-and-demos — what we’re building next\n• #platform-and-tools — questions, tips, and discoveries\n\nKeep a conversation focused by replying in a thread.",
                html:
                    "<p>A little structure for the week:</p><ul><li><strong>#team</strong> — updates and everyday conversations</li><li><strong>#planning-and-demos</strong> — what we’re building next</li><li><strong>#platform-and-tools</strong> — questions, tips, and discoveries</li></ul><p>Keep a conversation focused by replying in a thread.</p>",
                150, replies: 2,
                reactions: [.init(key: "🙌", count: 2, mine: true), .init(key: "✨", count: 1, mine: false)]),
            sample(
                "preview.share", 2,
                "The details make the difference. A familiar space, room to focus, and everything right where you expect it.",
                80),
            sample(
                "preview.try", 0,
                "Try opening a thread or switching channels. You can also make this space yours in Preferences → Appearance.",
                html:
                    "Try opening a thread or switching channels. You can also make this space yours in <strong>Preferences → Appearance</strong>.",
                40, reactions: [.init(key: "👍", count: 2, mine: false)]),
            sample("preview.you", 3, "Looking good! I’ll start with the team channel.", 34),
            sample(
                "preview.answer", 1, "Perfect. Use ⌘ K to jump to a conversation. See you in the channels 🚀",
                html: "Perfect. Use <code>⌘ K</code> to jump to a conversation. See you in the channels 🚀", 29),
        ]
    }
    func openPreviewThread(_ root: ChatMessage) {
        threadMessages = [
            root,
            ChatMessage(
                id: "preview.reply.1", roomID: root.roomID, senderID: "preview.sam", senderName: "Sam",
                body: "Threads make it much easier to follow along.", timestamp: root.timestamp.addingTimeInterval(120),
                threadRootID: root.eventID),
            ChatMessage(
                id: "preview.reply.2", roomID: root.roomID, senderID: "preview.julia", senderName: "Julia",
                body: "Exactly! Everything stays together, with room for the details.",
                timestamp: root.timestamp.addingTimeInterval(240), threadRootID: root.eventID),
        ]
    }
    func exitPreview() {
        guard canChangeAuthentication else { return }
        isPreview = false
        user = nil
        rooms = []
        workspaces = []
        messages = []
        threadMessages = []
        members = []
        selectedRoomID = nil
        status = .signedOut
    }
}
