package ai.nuanu.slatrix.core

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.matrix.rustcomponents.sdk.*

class MatrixSavedTest {
    // capability: message.save
    @Test fun aSavedMessageReadsAsItIsNowFromItsConversation() = runTest {
        val room = SavedRoom(Membership.JOINED)
        val preview = MatrixSaved(SavedClient(room)).preview(SavedMessage("!design:example.org", "\$one", 0))
        assertEquals(SavedPreview("@mira:example.org", "Mira Chen", "Edited to this", 1_700_000_000_000L), preview)
    }

    @Test fun aSavedMessageSanitizesMatrixMarkdownMentionsLinksAndFormatting() = runTest {
        val markdown = "[Dmitry Ukhanov](https://matrix.to/#/@dmitry.ukhanov:matrix.org) check `revit-work` and **bold** _notes_ in [the doc](https://example.org/doc) for my_var_name"
        val room = SavedRoom(Membership.JOINED, body = markdown)
        val preview = MatrixSaved(SavedClient(room)).preview(SavedMessage("!design:example.org", "\$md", 0))
        assertEquals("@Dmitry Ukhanov check revit-work and bold notes in the doc for my_var_name", preview?.body)
    }

    @Test fun aSavedMessageRendersFormattedHtmlMentionsAndHidesSpoilers() = runTest {
        val rawBody = "[Dmitry Ukhanov](https://matrix.to/#/@dmitry.ukhanov:matrix.org) secret `sshd`"
        val html = "<p><a href=\"https://matrix.to/#/@dmitry.ukhanov:matrix.org\">Dmitry Ukhanov</a> <span data-mx-spoiler>secret</span> <code>sshd</code></p>"
        val room = SavedRoom(Membership.JOINED, body = rawBody, html = html)
        val preview = MatrixSaved(SavedClient(room)).preview(SavedMessage("!design:example.org", "\$html", 0))
        assertEquals("@Dmitry Ukhanov [Spoiler hidden] sshd", preview?.body)
    }

    @Test fun aSavedMessageHidesSpoilersNestedInsideMentions() = runTest {
        val html = "<p><a href=\"https://matrix.to/#/@alice:example.org\"><span data-mx-spoiler>top-secret</span></a></p>"
        val room = SavedRoom(Membership.JOINED, body = "hidden", html = html)
        val preview = MatrixSaved(SavedClient(room)).preview(SavedMessage("!design:example.org", "\$spoiler", 0))
        assertEquals("[Spoiler hidden]", preview?.body)
    }

    @Test fun aConversationYouLeftHasNothingToShow() = runTest {
        assertNull(MatrixSaved(SavedClient(SavedRoom(Membership.LEFT))).preview(SavedMessage("!design:example.org", "\$one", 0)))
    }
}

private class SavedClient(private val room: Room) : Client(NoHandle) {
    override fun getRoom(roomId: String): Room = room
}

private class SavedRoom(private val membership: Membership, private val body: String = "Edited to this",
    private val html: String? = null) : Room(NoHandle) {
    override fun membership(): Membership = membership
    override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline {
        return object : Timeline(NoHandle) {
            override suspend fun getEventTimelineItemByEventId(eventId: String): EventTimelineItem = EventTimelineItem(
                isRemote = true, eventOrTransactionId = EventOrTransactionId.EventId(eventId), sender = "@mira:example.org",
                senderProfile = ProfileDetails.Ready("Mira Chen", false, null, null, null), forwarder = null,
                forwarderProfile = null, isOwn = false, isEditable = false,
                content = TimelineItemContent.MsgLike(MsgLikeContent(MsgLikeKind.Message(MessageContent(
                    MessageType.Text(TextMessageContent(body, html?.let { FormattedBody(MessageFormat.Html, it) })), body, true, null)), null, null, null)),
                reactions = emptyList(), eventTypeRaw = "m.room.message", timestamp = 1_700_000_000_000u, localSendState = null,
                editSendState = null, redactionSendState = null, localCreatedAt = null, readReceipts = emptyMap(), origin = null,
                canBeRepliedTo = true, lazyProvider = object : LazyTimelineItemProvider(NoHandle) {},
            )
        }
    }
}
