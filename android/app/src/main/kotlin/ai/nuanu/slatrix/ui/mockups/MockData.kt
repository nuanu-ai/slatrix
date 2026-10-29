package ai.nuanu.slatrix.ui.mockups

data class MockChannel(
    val id: String,
    val name: String,
    val topic: String,
    val unread: Boolean = false,
    val badge: String? = null,
    val direct: Boolean = false,
)

data class MockConversation(
    val id: String,
    val name: String,
    val initials: String,
    val preview: String,
    val time: String,
    val badge: String? = null,
    val colorIndex: Int = 0,
)

data class MockMessage(
    val id: String,
    val author: String,
    val initials: String,
    val time: String,
    val body: String,
    val colorIndex: Int = 0,
    val replyCount: Int = 0,
    val reaction: String? = null,
)

data class MockActivity(
    val id: String,
    val author: String,
    val initials: String,
    val action: String,
    val channel: String,
    val body: String,
    val time: String,
    val colorIndex: Int = 0,
)

data class MockProfile(val name: String, val initials: String, val title: String)

object MockData {
    val profile = MockProfile("Jordan Lee", "JL", "Product designer")
    val channels = listOf(
        MockChannel("design", "design", "Make the simple things feel effortless", true, "3"),
        MockChannel("general", "general", "A little bit of everything", true),
        MockChannel("product", "product", "What we're making next", true, "1"),
        MockChannel("engineering", "engineering", "Building it together"),
        MockChannel("announcements", "announcements", "The latest from Studio"),
        MockChannel("random", "random", "The good stuff between the work"),
        MockChannel("team-london", "team-london", "Hello from London"),
        MockChannel("good-reads", "good-reads", "Worth a few minutes"),
    )
    val conversations = listOf(
        MockConversation("ava", "Ava Patel", "AP", "Love this direction. The spacing feels much better.", "10:42", "2", 1),
        MockConversation("sam", "Sam Taylor", "ST", "You: Let's pick this up after lunch.", "10:18", colorIndex = 2),
        MockConversation("mia", "Mia Chen", "MC", "Shared a file: Brand guidelines.pdf", "09:56", "1", 4),
        MockConversation("leo", "Leo Martin", "LM", "Thanks, Jordan! See you there.", "Yesterday", colorIndex = 3),
        MockConversation("nina", "Nina Wilson", "NW", "The new icons are ready for a look.", "Yesterday", colorIndex = 5),
    )
    val threadParent = MockMessage(
        "design-review", "Ava Patel", "AP", "10:32", "A first look at the new channel header. More room for the conversation, less in the way.\n\nWhat do you think?", 1, 3, "4",
    )
    val messages = listOf(
        MockMessage("morning", "Sam Taylor", "ST", "10:24", "Morning team! The latest explorations are ready for a look.", 2),
        threadParent,
        MockMessage("feedback", "Jordan Lee", "JL", "10:38", "This feels really good. Let's keep the topic visible and give the message a little more breathing room.", 0, reaction = "2"),
        MockMessage("next", "Sam Taylor", "ST", "10:41", "Agreed. I'll try that in the next pass.", 2),
    )
    val replies = listOf(
        MockMessage("reply-1", "Jordan Lee", "JL", "10:35", "Love the simpler header. Could we try it with a longer channel name too?"),
        MockMessage("reply-2", "Sam Taylor", "ST", "10:36", "Good call. I'll add that to the next version.", 2),
        MockMessage("reply-3", "Ava Patel", "AP", "10:39", "On it! I'll share an update here this afternoon.", 1),
    )
    val activity = listOf(
        MockActivity("mention-1", "Ava Patel", "AP", "mentioned you", "design", "@Jordan Lee would love your thoughts on the new channel header.", "10:42", 1),
        MockActivity("thread-1", "Ava Patel", "AP", "replied to a thread", "design", "On it! I'll share an update here this afternoon.", "10:39", 1),
        MockActivity("thread-2", "Sam Taylor", "ST", "replied to a thread", "design", "Good call. I'll add that to the next version.", "10:36", 2),
    )
}
