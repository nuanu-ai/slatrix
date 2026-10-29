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
        assertEquals(SavedPreview("Mira Chen", "Edited to this", 1_700_000_000_000L), preview)
        assertEquals(TimelineFocus.Event("\$one", 0u, uniffi.matrix_sdk_ui.TimelineEventFocusThreadMode.Automatic(false)), room.focus)
    }

    @Test fun aConversationYouLeftHasNothingToShow() = runTest {
        assertNull(MatrixSaved(SavedClient(SavedRoom(Membership.LEFT))).preview(SavedMessage("!design:example.org", "\$one", 0)))
    }
}

private class SavedClient(private val room: Room) : Client(NoHandle) {
    override fun getRoom(roomId: String): Room = room
}

private class SavedRoom(private val membership: Membership) : Room(NoHandle) {
    var focus: TimelineFocus? = null
    override fun membership(): Membership = membership
    override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline {
        focus = configuration.focus
        return object : Timeline(NoHandle) {
            override suspend fun getEventTimelineItemByEventId(eventId: String): EventTimelineItem = EventTimelineItem(
                isRemote = true, eventOrTransactionId = EventOrTransactionId.EventId(eventId), sender = "@mira:example.org",
                senderProfile = ProfileDetails.Ready("Mira Chen", false, null, null, null), forwarder = null,
                forwarderProfile = null, isOwn = false, isEditable = false,
                content = TimelineItemContent.MsgLike(MsgLikeContent(MsgLikeKind.Message(MessageContent(
                    MessageType.Text(TextMessageContent("Edited to this", null)), "Edited to this", true, null)), null, null, null)),
                reactions = emptyList(), eventTypeRaw = "m.room.message", timestamp = 1_700_000_000_000u, localSendState = null,
                editSendState = null, redactionSendState = null, localCreatedAt = null, readReceipts = emptyMap(), origin = null,
                canBeRepliedTo = true, lazyProvider = object : LazyTimelineItemProvider(NoHandle) {},
            )
        }
    }
}
