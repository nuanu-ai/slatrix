package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.*
import uniffi.matrix_sdk_ui.TimelineEventFocusThreadMode

class MatrixConversationTest {
    // capability: conversation.history
    @Test fun cachedMessagesAppearWhileOlderHistoryIsStillLoading() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val message = conversation.state.first { !it.loading }.rows.messages.single()
        assertEquals("stable-1", message.id)
        assertEquals("\$one", message.eventId)
        assertEquals("Hello", message.body)
        assertEquals("Mira Chen", message.senderName)
        assertEquals("MC", message.initials)
        conversation.close()
    }

    @Test fun aResetOrClearedTimelineLoadsOlderHistoryAgain() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { it.rows.isNotEmpty() }
        conversation.loadOlder()
        timeline.page.complete(true)
        conversation.state.first { !it.hasMore }

        timeline.emit(listOf(TimelineDiff.Reset(listOf(conversationItem("stable-2", "\$two", "Again")))))
        assertTrue(conversation.state.first { it.rows.messages.firstOrNull()?.id == "stable-2" }.hasMore)
        conversation.loadOlder()
        conversation.state.first { !it.hasMore }
        timeline.emit(listOf(TimelineDiff.Clear))
        assertTrue(conversation.state.first { it.rows.messages.isEmpty() }.hasMore)
        conversation.close()
    }

    @Test fun aFailedReadReceiptStaysQuietAndALaterReadRetries() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { it.rows.messages.isNotEmpty() }
        timeline.receiptFailure = IllegalStateException("Offline")

        assertFalse(conversation.markRead("\$one"))
        assertNull(conversation.state.value.error)
        timeline.receiptFailure = null
        assertTrue(conversation.markRead("\$one"))
        assertEquals(ReceiptType.READ to "\$one", timeline.receipts.receive())
        conversation.close()
    }

    @Test fun retryLoadsFailedHistoryAgainWithoutLosingMessages() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        timeline.pageFailure = IllegalStateException("Offline")
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { !it.loading }
        repeat(20) { conversation.loadOlder(); runCurrent() }
        assertNotNull(conversation.state.value.error)
        assertTrue(conversation.markRead("\$one"))
        assertNotNull("Reading must not hide the history error", conversation.state.value.error)

        timeline.pageFailure = null
        timeline.page.complete(true)
        assertTrue(conversation.retry())
        val loaded = conversation.state.first { !it.hasMore }
        assertNull(loaded.error)
        assertEquals(listOf("Hello"), loaded.rows.messages.map { it.body })
        conversation.close()
    }

    @Test fun retryLeavesATimelineThatNeverOpenedToBeReopened() = runTest {
        val room = ConversationRoom(ConversationTimeline(emptyList()))
        room.openFailure = IllegalStateException("Store unavailable")
        val conversation = MatrixConversation(backgroundScope, room)
        conversation.state.first { it.error != null }
        assertFalse(conversation.retry())
        conversation.close()
    }

    @Test fun retryLeavesATimelineThatStoppedUpdatingToBeReopened() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { !it.loading }
        timeline.emit(listOf(TimelineDiff.Remove(9u)))
        conversation.state.first { it.error != null }
        assertFalse(conversation.retry())
        conversation.close()
    }

    @Test fun timelineUpdatesAreMappedOffTheCallersThread() = runTest {
        val caller = Thread.currentThread()
        var mappedOn: Thread? = null
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello") { mappedOn = Thread.currentThread() }))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { it.rows.messages.isNotEmpty() }
        assertNotSame(caller, mappedOn)
        conversation.close()
    }

    @Test fun dayDividersSplitTheTimelineAndASendersRunGroupsWithinFiveMinutes() = runTest {
        val start = 1_700_000_000_000uL
        val minute = 60_000uL
        val timeline = ConversationTimeline(listOf(
            dateDivider("day-1", start),
            conversationItem("a", "\$a", "First", timestamp = start),
            conversationItem("b", "\$b", "Second", timestamp = start + minute),
            conversationItem("c", "\$c", "Third", sender = "@sam:example.org", timestamp = start + 2u * minute),
            conversationItem("d", "\$d", "Fourth", sender = "@sam:example.org", timestamp = start + 7u * minute),
            dateDivider("day-2", start + 8u * minute),
            conversationItem("e", "\$e", "Fifth", sender = "@sam:example.org", timestamp = start + 8u * minute),
        ))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val rows = conversation.state.first { it.rows.isNotEmpty() }.rows
        assertEquals(listOf("day", "First", "+Second", "Third", "Fourth", "day", "Fifth"), rows.map {
            when (it) { is DayDivider -> "day"; is ConversationMessage -> if (it.grouped) "+${it.body}" else it.body }
        })
        assertEquals(1_700_000_000_000L, (rows.first() as DayDivider).timestamp)

        timeline.emit(listOf(TimelineDiff.Remove(1u)))
        assertEquals("Removing the run's first message ungroups the next", listOf("day", "Second", "Third"),
            conversation.state.first { it.rows.size == 6 }.rows.take(3).map { (it as? ConversationMessage)?.body ?: "day" })
        conversation.close()
    }

    @Test fun aDayWithOnlyEventsTheAppHidesShowsNoDivider() = runTest {
        val start = 1_700_000_000_000uL
        val day = 86_400_000uL
        // The SDK starts a day at its first event of any kind, so days of joins or topic changes still get a divider.
        val timeline = ConversationTimeline(listOf(
            dateDivider("joins-only", start),
            dateDivider("with-message", start + day),
            conversationItem("a", "\$a", "First", timestamp = start + day),
            dateDivider("topic-only", start + 2u * day),
        ))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        assertEquals(listOf("with-message", "a"), conversation.state.first { it.rows.isNotEmpty() }.rows.map { it.id })
        conversation.close()
    }

    @Test fun historyStopsAfterPagesOfHiddenEventsUntilAnOlderMessageShows() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        timeline.page.complete(false)
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { it.rows.isNotEmpty() }
        repeat(20) { conversation.loadOlder(); runCurrent() }
        val stopped = timeline.pages
        assertTrue("Pages of hidden events stop on their own", stopped < 20)

        timeline.emit(listOf(TimelineDiff.PushFront(conversationItem("stable-0", "\$zero", "Earlier"))))
        conversation.state.first { it.rows.first().id == "stable-0" }
        conversation.loadOlder()
        runCurrent()
        assertEquals("An older message lets history page again", stopped + 1, timeline.pages)
        conversation.close()
    }

    // capability: message.retry-failed
    @Test fun failedMessagesResumeTheQueueResendOrDelete() = runTest {
        val offline = EventSendState.SendingFailed(QueueWedgeError.GenericApiError("Offline"), true)
        val rejected = EventSendState.SendingFailed(QueueWedgeError.GenericApiError("Rejected"), false)
        val expired = EventSendState.SendingFailed(QueueWedgeError.ExpiredAccessToken, false)
        val timeline = ConversationTimeline(listOf(
            conversationItem("a", "txn-a", "Offline", local = true, sendState = offline),
            conversationItem("b", "txn-b", "Rejected", local = true, sendState = rejected),
            conversationItem("c", "txn-c", "Expired", local = true, sendState = expired),
        ))
        val room = ConversationRoom(timeline)
        val conversation = MatrixConversation(backgroundScope, room)
        val (a, b, c) = conversation.state.first { it.rows.size == 3 }.rows.messages
        assertEquals(listOf(MessageSendState.Failed, MessageSendState.Failed, MessageSendState.Failed), listOf(a, b, c).map { it.sendState })
        assertEquals(listOf(true, true, false), listOf(a, b, c).map { it.canRetry })

        conversation.retrySend(a)
        assertTrue(room.sendQueueEnabled.await())
        conversation.retrySend(b)
        assertEquals(EventOrTransactionId.TransactionId("txn-b"), timeline.retried.receive())
        conversation.deleteUnsent(c)
        assertEquals(EventOrTransactionId.TransactionId("txn-c"), timeline.aborted.receive())
        conversation.close()
    }

    // capability: composer.send
    @Test fun sendPreservesComposerFieldsAndAcceptsOnlyTheSdkQueueResult() = runTest {
        val timeline = ConversationTimeline(emptyList())
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        runCurrent()
        val message = ComposerMessage(
            body = "Hello Mira", html = "Hello <strong>Mira</strong>",
            mentions = listOf("@mira:example.org"), mentionsRoom = true,
        )
        val sending = async { conversation.send(message) }
        runCurrent()
        assertTrue(conversation.state.value.sending)
        val content = timeline.submissions.receive()
        val text = (content.type as MessageType.Text).content
        assertEquals("Hello Mira", text.body)
        assertEquals("Hello <strong>Mira</strong>", text.formatted?.body)
        assertEquals(listOf("@mira:example.org"), content.mentions?.userIds)
        assertEquals(true, content.mentions?.room)
        assertEquals(emptyList<ConversationMessage>(), conversation.state.value.rows.messages)
        timeline.sendResults.send(Result.success(object : SendHandle(NoHandle) {}))
        assertTrue(sending.await())
        assertEquals(emptyList<ConversationMessage>(), conversation.state.value.rows.messages)

        val rejected = async { conversation.send(message) }
        timeline.submissions.receive()
        timeline.sendResults.send(Result.failure(IllegalStateException("Store unavailable")))
        assertFalse(rejected.await())
        assertNotNull(conversation.state.value.sendError)
        conversation.close()
    }

    // capability: message.reactions.show
    @Test fun reactionsCountTheirSendersAndMarkYours() = runTest {
        fun sent(id: String) = ReactionSenderData(id, 1_700_000_000_000u, null)
        val timeline = ConversationTimeline(listOf(conversationItem("a", "\$a", "Ship it", reactions = listOf(
            Reaction("👍", listOf(sent("@mira:example.org"), sent("@me:example.org"))),
            Reaction("🎉", listOf(sent("@sam:example.org"))),
        ))))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val state = conversation.state.first { it.rows.isNotEmpty() }
        assertEquals(listOf(
            MessageReaction("👍", 2, true, listOf("@mira:example.org", "@me:example.org")),
            MessageReaction("🎉", 1, false, listOf("@sam:example.org")),
        ), state.rows.messages.single().reactions)
        assertEquals("@me:example.org", state.ownUserId)
        conversation.close()
    }

    // capability: message.thread-summary
    @Test fun aThreadRootCountsItsRepliesAndKnowsTheLastOne() = runTest {
        val reply = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent("Done", null)), "Done", false, null)), null, null, null))
        val summary = object : ThreadSummary(NoHandle) {
            override fun numReplies(): ULong = 3u
            override fun latestEvent(): EmbeddedEventDetails = EmbeddedEventDetails.Ready(reply, "@sam:example.org",
                ProfileDetails.Ready("Sam Okafor", false, null, null, null), 1_700_000_600_000u, EventOrTransactionId.EventId("\$r"))
        }
        val root = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent("Plan?", null)), "Plan?", false, null)), null, null, summary))
        val timeline = ConversationTimeline(listOf(conversationItem("a", "\$a", "Plan?", content = root), conversationItem("b", "\$b", "Solo")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val messages = conversation.state.first { it.rows.isNotEmpty() }.rows.messages
        assertEquals(listOf(MessageThread(3, "Sam Okafor", 1_700_000_600_000L), null), messages.map { it.thread })
        conversation.close()
    }

    // capability: message.reply-preview
    @Test fun aReplyQuotesItsParentAndAsksForOneTheTimelineHasNotLoaded() = runTest {
        fun text(body: String) = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)), null, null, null))
        fun reply(parent: String, details: EmbeddedEventDetails) = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent("Yes", null)), "Yes", false, null)),
            object : InReplyToDetails(NoHandle) {
                override fun eventId(): String = parent
                override fun event(): EmbeddedEventDetails = details
            }, null, null))
        val ready = EmbeddedEventDetails.Ready(text("Ship it?"), "@sam:example.org",
            ProfileDetails.Ready("Sam Okafor", false, null, null, null), 1_700_000_000_000u, EventOrTransactionId.EventId("\$p"))
        val timeline = ConversationTimeline(listOf(
            conversationItem("a", "\$a", "Yes", content = reply("\$p", ready)),
            conversationItem("b", "\$b", "Yes", content = reply("\$old", EmbeddedEventDetails.Unavailable)),
            conversationItem("c", "\$c", "Yes", content = reply("\$old", EmbeddedEventDetails.Unavailable)),
        ))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val messages = conversation.state.first { it.rows.isNotEmpty() }.rows.messages
        assertEquals(listOf(
            ReplyPreview("\$p", ReplyPreview.State.Ready, "Sam Okafor", "Ship it?"),
            ReplyPreview("\$old", ReplyPreview.State.Loading),
            ReplyPreview("\$old", ReplyPreview.State.Loading),
        ), messages.map { it.replyTo })
        assertEquals("\$old", timeline.fetched.receive())
        conversation.close()
        assertTrue("Asked once for a parent two replies quote", timeline.fetched.tryReceive().isFailure)
    }

    // capability: message.image
    // capability: message.file
    @Test fun attachmentsCarryWhatTheirRowNeedsAndACaptionIsTheirText() = runTest {
        val source = object : MediaSource(NoHandle) { override fun url(): String = "mxc://example.org/photo" }
        val thumbnail = object : MediaSource(NoHandle) { override fun url(): String = "mxc://example.org/thumb" }
        fun item(id: String, body: String, type: MessageType) = conversationItem(id, "\$$id", body, content = TimelineItemContent.MsgLike(
            MsgLikeContent(MsgLikeKind.Message(MessageContent(type, body, false, null)), null, null, null)))
        val timeline = ConversationTimeline(listOf(
            item("a", "Our new office", MessageType.Image(ImageMessageContent("office.jpg", "Our new office", null, source,
                ImageInfo(900u, 1600u, "image/jpeg", 2_000_000u, null, thumbnail, null, false)))),
            item("b", "Q3 report.pdf", MessageType.File(FileMessageContent("Q3 report.pdf", null, null, source,
                FileInfo("application/pdf", 250_000u, null, null)))),
        ))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val (image, file) = conversation.state.first { it.rows.isNotEmpty() }.rows.messages
        assertEquals(MessageAttachment(MessageAttachment.Kind.Image, "office.jpg", "image/jpeg", 2_000_000, 1600, 900, source, thumbnail),
            image.attachment)
        assertEquals("Our new office", image.body)
        assertEquals(MessageAttachment(MessageAttachment.Kind.File, "Q3 report.pdf", "application/pdf", 250_000, null, null, source),
            file.attachment)
        conversation.close()
    }

    // capability: message.edited
    @Test fun anEditedMessageSaysSo() = runTest {
        val edited = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent("Fixed", null)), "Fixed", true, null)),
            null, null, null,
        ))
        val timeline = ConversationTimeline(listOf(conversationItem("a", "\$a", "Fixed", content = edited), conversationItem("b", "\$b", "Plain")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        assertEquals(listOf(true, false), conversation.state.first { it.rows.isNotEmpty() }.rows.messages.map { it.edited })
        conversation.close()
    }

    // capability: message.react.quick
    @Test fun reactingTogglesTheReactionOnTheMessageAndSaysWhenItAddedOne() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val message = conversation.state.first { it.rows.isNotEmpty() }.rows.messages.single()
        val added = CompletableDeferred<Unit>()
        conversation.react(message, "👍") { added.complete(Unit) }
        assertEquals(EventOrTransactionId.EventId("\$one") to "👍", timeline.reactions.receive())
        added.await()
        conversation.close()
    }

    // capability: message.delete
    @Test fun deletingASentMessageRedactsIt() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val message = conversation.state.first { it.rows.isNotEmpty() }.rows.messages.single()
        conversation.delete(message)
        assertEquals(EventOrTransactionId.EventId("\$one"), timeline.redacted.receive())
        conversation.close()
    }

    // capability: message.reply
    @Test fun aReplyQuotesItsMessageAndAnEditReplacesYourOwn() = runTest {
        val emote = TimelineItemContent.MsgLike(MsgLikeContent(MsgLikeKind.Message(MessageContent(
            MessageType.Emote(EmoteMessageContent("waves", null)), "waves", false, null)), null, null, null))
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello", editable = true),
            conversationItem("stable-2", "\$two", "", editable = true, content = emote)))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val (text, waving) = conversation.state.first { it.rows.isNotEmpty() }.rows.messages
        assertTrue(text.editable)
        assertFalse("An edit goes out as text, so a /me stays as it is", waving.editable)

        val reply = async { conversation.send(ComposerMessage("Agreed", null, emptyList(), false, ComposerTarget.Reply("\$one", "Mira Chen", "Hello"))) }
        assertEquals("\$one", timeline.replies.receive())
        assertEquals("Agreed", ((timeline.submissions.receive().type) as MessageType.Text).content.body)
        timeline.sendResults.send(Result.success(object : SendHandle(NoHandle) {}))
        assertTrue(reply.await())

        assertTrue(conversation.send(ComposerMessage("Hello again", null, emptyList(), false, ComposerTarget.Edit("\$one", "Hello"))))
        val (id, edited) = timeline.edits.receive()
        assertEquals(EventOrTransactionId.EventId("\$one"), id)
        assertEquals("Hello again", (((edited as EditedContent.RoomMessage).content as ConversationContent).type as MessageType.Text).content.body)
        conversation.close()
    }

    // capability: composer.attachments
    @Test fun attachmentsGoOutInOrderAsImagesAndVideosWithTheirSizeOrAsFilesAndShowTheirUpload() = runTest {
        val uploading = EventSendState.NotSentYet(MediaUploadProgress(0u, AbstractProgress(25u, 100u)))
        val timeline = ConversationTimeline(listOf(conversationItem("a", "txn-a", "photo.png", local = true, sendState = uploading)))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        assertEquals(0.25f, conversation.state.first { it.rows.isNotEmpty() }.rows.messages.single().uploadProgress)

        conversation.sendAttachments(listOf(
            { OutgoingAttachment("/cache/photo.png", "photo.png", "image/png", 2_048, 1200, 800) },
            { OutgoingAttachment("/cache/notes.pdf", "notes.pdf", "application/pdf", 4_096, null, null) },
            { OutgoingAttachment("/cache/clip.mp4", "clip.mp4", "video/mp4", 8_192, 640, 360, durationMillis = 3_000) },
        ))
        val (photo, image) = timeline.attachments.receive()
        assertEquals(UploadSource.File("/cache/photo.png"), photo.source)
        assertEquals(ImageInfo(800u, 1200u, "image/png", 2_048u, null, null, null, null), (image as AttachmentKind.Image).imageInfo)
        val (notes, file) = timeline.attachments.receive()
        assertEquals(UploadSource.File("/cache/notes.pdf"), notes.source)
        assertEquals(FileInfo("application/pdf", 4_096u, null, null), (file as AttachmentKind.File).fileInfo)
        val (_, video) = timeline.attachments.receive()
        assertEquals(VideoInfo(java.time.Duration.ofMillis(3_000), 360u, 640u, "video/mp4", 8_192u, null, null, null),
            (video as AttachmentKind.Video).videoInfo)
        conversation.close()
    }

    @Test fun anAttachmentInAThreadGoesToTheThread() = runTest {
        val timeline = ConversationTimeline(emptyList())
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline), threadRoot = "\$root")
        conversation.sendAttachments(listOf({ OutgoingAttachment("/cache/a.txt", "a.txt", "text/plain", 1, null, null) }))
        val relation = com.google.gson.JsonParser.parseString(timeline.attachments.receive().first.extraContentJson).asJsonObject["m.relates_to"].asJsonObject
        assertEquals("m.thread", relation["rel_type"].asString)
        assertEquals("\$root", relation["event_id"].asString)
        conversation.close()
    }

    @Test fun anAttachmentThatCantBeReadSaysSo() = runTest {
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(ConversationTimeline(emptyList())))
        conversation.sendAttachments(listOf({ throw java.io.FileNotFoundException("gone") }))
        assertEquals("Couldn’t send this file.", conversation.state.first { it.notice != null }.notice)
        conversation.close()
    }

    // capability: message.pin
    @Test fun pinningPinsOrUnpinsTheMessageAndAFailureSaysSo() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val message = conversation.state.first { it.rows.isNotEmpty() }.rows.messages.single()
        conversation.pin(message, true)
        assertEquals("\$one" to true, timeline.pins.receive())
        conversation.pin(message, false)
        assertEquals("\$one" to false, timeline.pins.receive())

        timeline.pinFailure = IllegalStateException("Forbidden")
        conversation.pin(message, true)
        assertEquals("Couldn’t pin this message.", conversation.state.first { it.notice != null }.notice)
        conversation.close()
    }

    // capability: conversation.pins
    @Test fun pinnedMessagesComeFromTheRoomsPinnedTimeline() = runTest {
        val room = ConversationRoom(ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Ship it"))))
        val pinned = MatrixConversation(backgroundScope, room, view = ConversationView.Pins)
        assertEquals(listOf("Ship it"), pinned.state.first { it.rows.isNotEmpty() }.rows.messages.map { it.body })
        assertTrue(room.configuration?.focus is TimelineFocus.PinnedEvents)
        pinned.close()
    }

    // capability: conversation.files
    @Test fun sharedFilesReadTheWholeConversationThreadsIncluded() = runTest {
        val room = ConversationRoom(ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "spec.pdf"))))
        val files = MatrixConversation(backgroundScope, room, view = ConversationView.Files)
        files.state.first { it.rows.isNotEmpty() }
        assertEquals(TimelineFocus.Live(hideThreadedEvents = false), room.configuration?.focus)
        files.close()
    }

    // capability: message.edit-caption
    @Test fun aCaptionChangesOrGoesByEditingTheMediaEvent() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Our new office")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val message = conversation.state.first { it.rows.isNotEmpty() }.rows.messages.single()
        conversation.editCaption(message, "Our new office, 3rd floor")
        assertEquals(EventOrTransactionId.EventId("\$one") to EditedContent.MediaCaption("Our new office, 3rd floor", null,
            Mentions(emptyList(), false)), timeline.edits.receive())
        conversation.editCaption(message, null)
        assertEquals(EditedContent.MediaCaption(null, null, Mentions(emptyList(), false)), timeline.edits.receive().second)

        timeline.editFailure = IllegalStateException("Offline")
        conversation.editCaption(message, "Again")
        assertEquals("Couldn’t change the caption.", conversation.state.first { it.notice != null }.notice)
        conversation.close()
    }

    // capability: message.video
    @Test fun aVideoCarriesItsLengthAndSizeForItsPoster() = runTest {
        val source = object : MediaSource(NoHandle) { override fun url(): String = "mxc://example.org/clip" }
        val poster = object : MediaSource(NoHandle) { override fun url(): String = "mxc://example.org/poster" }
        val timeline = ConversationTimeline(listOf(conversationItem("a", "\$a", "clip.mp4", content = TimelineItemContent.MsgLike(
            MsgLikeContent(MsgLikeKind.Message(MessageContent(MessageType.Video(VideoMessageContent("clip.mp4", null, null, source,
                VideoInfo(java.time.Duration.ofSeconds(83), 720u, 1280u, "video/mp4", 5_000_000u, ThumbnailInfo(720u, 1280u, "image/jpeg", 40_000u),
                    poster, null))), "clip.mp4", false, null)), null, null, null)))))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val video = conversation.state.first { it.rows.isNotEmpty() }.rows.messages.single()
        assertEquals(MessageAttachment(MessageAttachment.Kind.Video, "clip.mp4", "video/mp4", 5_000_000, 1280, 720, source, poster, 40_000,
            durationMillis = 83_000), video.attachment)
        conversation.close()
    }

    @Test fun aFailedDeleteSaysSoForAMoment() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        timeline.redactFailure = IllegalStateException("Offline")
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val message = conversation.state.first { it.rows.isNotEmpty() }.rows.messages.single()
        conversation.delete(message)
        assertEquals("Couldn’t delete this message.", conversation.state.first { it.notice != null }.notice)
        conversation.state.first { it.notice == null }
        assertEquals(listOf("Hello"), conversation.state.value.rows.messages.map { it.body })
        conversation.close()
    }

    // capability: message.forward
    @Test fun aMessageForwardsAsItsTextOrItsMediaButNotWhileAnEditOrDeleteIsPending() = runTest {
        fun media(type: MessageType) = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(type, "clip", false, null)), null, null, null))
        val source = object : MediaSource(NoHandle) {}
        val file = MessageType.File(FileMessageContent("plan.pdf", null, null, source, null))
        val video = MessageType.Video(VideoMessageContent("clip.mp4", null, null, source, null))
        val audio = MessageType.Audio(AudioMessageContent("memo.m4a", null, null, source, null, null, null))
        val timeline = ConversationTimeline(listOf(
            conversationItem("a", "\$text", "Ship it"),
            conversationItem("b", "\$file", "plan.pdf", content = media(file)),
            conversationItem("c", "\$video", "clip.mp4", content = media(video)),
            conversationItem("d", "\$editing", "Being edited", editState = EventSendState.NotSentYet(null)),
            conversationItem("e", "\$deleting", "Being deleted", deleting = true),
            conversationItem("f", "\$audio", "memo.m4a", content = media(audio)),
        ))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val rows = conversation.state.first { it.rows.messages.size == 6 }.rows.messages

        assertEquals(MessageType.Text(TextMessageContent("Ship it", null)), conversation.forwardable(rows[0]))
        assertEquals(file, conversation.forwardable(rows[1]))
        assertEquals(video, conversation.forwardable(rows[2]))
        assertNull("A pending edit could change what goes", conversation.forwardable(rows[3]))
        assertNull(conversation.forwardable(rows[4]))
        assertEquals(audio, conversation.forwardable(rows[5]))
        conversation.close()
    }

    // capability: message.copy-link
    @Test fun aMessageLinksToItsEventInTheRoom() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val message = conversation.state.first { it.rows.isNotEmpty() }.rows.messages.single()
        assertEquals("https://matrix.to/#/!design:example.org/\$one", conversation.link(message))
        conversation.close()
    }

    // capability: conversation.read
    @Test fun onlyVisibleLatestMessagesAreReadAndClosedTimelinesRejectLateUpdates() = runTest {
        val divider = object : TimelineItem(NoHandle) {
            override fun asEvent(): EventTimelineItem? = null
            override fun asVirtual(): VirtualTimelineItem = VirtualTimelineItem.ReadMarker
        }
        val timeline = ConversationTimeline(listOf(
            divider,
            conversationItem("stable-old", "\$old", "Earlier"),
            conversationItem("stable-new", "transaction", "Queued", local = true),
        ))
        val room = ConversationRoom(timeline)
        val conversation = MatrixConversation(backgroundScope, room)
        conversation.loadOlder()
        timeline.pageStarted.await()
        assertEquals(MessageSendState.Sending, conversation.state.first { it.rows.messages.size == 2 }.rows.messages.last().sendState)

        timeline.emit(listOf(TimelineDiff.Set(2u, conversationItem("stable-new", "\$new", "Delivered"))))
        conversation.state.first { it.rows.messages.last().body == "Delivered" }
        assertEquals("stable-new", conversation.state.value.rows.messages.last().id)
        assertEquals("\$new", conversation.state.value.rows.messages.last().eventId)
        assertEquals(MessageSendState.Sent, conversation.state.value.rows.messages.last().sendState)
        val encrypted = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.UnableToDecrypt(EncryptedMessage.Unknown), null, null, null,
        ))
        timeline.emit(listOf(TimelineDiff.Set(2u, conversationItem("stable-new", "\$new", "", content = encrypted))))
        conversation.state.first { it.rows.messages.last().kind == MessageKind.Encrypted }
        assertEquals(MessageKind.Encrypted, conversation.state.value.rows.messages.last().kind)
        assertEquals("Waiting for this message", conversation.state.value.rows.messages.last().body)

        assertFalse(conversation.markRead("\$old"))
        assertTrue(timeline.receipts.tryReceive().isFailure)
        assertTrue(room.markedUnread)
        assertTrue(conversation.markRead("\$new"))
        assertEquals(ReceiptType.READ to "\$new", timeline.receipts.receive())
        assertEquals(ReceiptType.FULLY_READ to "\$new", timeline.receipts.receive())
        assertFalse(room.markedUnread)
        assertTrue(conversation.markRead("\$new"))
        assertTrue(timeline.receipts.tryReceive().isFailure)
        assertEquals(TimelineFocus.Live(true), room.configuration?.focus)

        conversation.close()
        timeline.listenerCancelled.await()
        timeline.pageCancelled.await()
        val closed = conversation.state.value
        timeline.emit(listOf(TimelineDiff.PushBack(conversationItem("late", "\$late", "Too late"))))
        assertEquals(closed, conversation.state.value)
    }

    // capability: thread.read-state
    @Test fun aThreadSendsOnlyItsOwnReadReceiptAndLeavesTheChannelUnread() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("root", "\$root", "Plan?"), conversationItem("reply", "\$reply", "Yes")))
        val room = ConversationRoom(timeline)
        val conversation = MatrixConversation(backgroundScope, room, threadRoot = "\$root")
        conversation.state.first { it.rows.isNotEmpty() }

        assertTrue(conversation.markRead("\$reply"))
        assertEquals(ReceiptType.READ to "\$reply", timeline.receipts.receive())
        assertTrue("The channel's own read marker must not move", timeline.receipts.tryReceive().isFailure)
        assertTrue("Reading a thread must not clear the channel's unread mark", room.markedUnread)
        conversation.close()
    }

    // capability: conversation.jump-to-message
    @Test fun aMessageTheLiveTimelineHoldsOpensLiveAndHighlighted() = runTest {
        val live = ConversationTimeline(listOf(conversationItem("a", "\$a", "Hello"), conversationItem("b", "\$b", "World")))
        val room = JumpRoom(live, ConversationTimeline(emptyList()))
        val conversation = MatrixConversation(backgroundScope, room, at = "\$b")

        val opened = conversation.state.first { !it.loading }
        assertEquals("\$b", opened.highlight)
        assertFalse(opened.focused)
        assertEquals(listOf<TimelineFocus>(TimelineFocus.Live(true)), room.focuses)
        assertTrue(conversation.markRead("\$b"))
        conversation.close()
    }

    // capability: conversation.jump-to-message
    @Test fun anOlderMessageOpensAroundItAndTurnsLiveOnceTheReaderReachesTheNewest() = runTest {
        val live = ConversationTimeline(listOf(conversationItem("new", "\$new", "Latest")))
        val around = ConversationTimeline(listOf(conversationItem("old", "\$old", "Earlier")))
        val room = JumpRoom(live, around)
        val conversation = MatrixConversation(backgroundScope, room, at = "\$old")

        val opened = conversation.state.first { !it.loading }
        assertEquals("The live rows that don't reach it never show", listOf("Earlier"), opened.rows.messages.map { it.body })
        assertEquals("\$old", opened.highlight)
        assertTrue(opened.focused)
        assertEquals(TimelineFocus.Event("\$old", 30u, TimelineEventFocusThreadMode.Automatic(true)), room.focuses.last())
        assertFalse("Opening at an old message doesn't mean the newest was read", conversation.markRead("\$old"))

        conversation.loadNewer("\$old")
        live.pageStarted.await()
        live.emit(listOf(TimelineDiff.PushFront(conversationItem("old-live", "\$old", "Earlier"))))
        live.page.complete(false)
        val joined = conversation.state.first { !it.focused }
        assertEquals(listOf("Earlier", "Latest"), joined.rows.messages.map { it.body })
        assertTrue(conversation.markRead("\$new"))
        conversation.close()
    }

    // capability: conversation.jump-to-message
    @Test fun aMessageWhoseSurroundingsCantLoadStillOpensTheConversationLive() = runTest {
        val live = ConversationTimeline(listOf(conversationItem("new", "\$new", "Latest")))
        val room = JumpRoom(live, ConversationTimeline(emptyList())).apply { aroundFailure = IllegalStateException("Offline") }
        val conversation = MatrixConversation(backgroundScope, room, at = "\$old")

        val opened = conversation.state.first { !it.loading }
        assertEquals(listOf("Latest"), opened.rows.messages.map { it.body })
        assertNull(opened.error)
        assertFalse(opened.focused)
        conversation.close()
    }

    // capability: conversation.unread-line
    @Test fun theNewLineGoesAboveTheFirstMessageAfterTheReadMarkerAndNeverInAThread() = runTest {
        val items = listOf(conversationItem("a", "\$a", "Read"), readMarker(), conversationItem("b", "\$b", "Unread"))
        val timeline = ConversationTimeline(items)
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        assertEquals("\$b", conversation.state.first { !it.loading }.firstUnread)
        // Reading moves the marker after the newest message.
        timeline.emit(listOf(TimelineDiff.Remove(1u), TimelineDiff.PushBack(readMarker())))
        conversation.state.first { it.firstUnread == null }
        conversation.close()

        val thread = MatrixConversation(backgroundScope, ConversationRoom(ConversationTimeline(items)), threadRoot = "\$a")
        assertNull(thread.state.first { !it.loading }.firstUnread)
        thread.close()
    }

    // capability: conversation.unread-line
    @Test fun anUnreadConversationOpensAroundWhereItsUnreadMessagesStartWithoutAHighlight() = runTest {
        val live = ConversationTimeline(listOf(conversationItem("new", "\$new", "Latest")))
        val around = ConversationTimeline(listOf(conversationItem("old", "\$old", "Earlier"), readMarker(),
            conversationItem("next", "\$next", "Unread")))
        val room = JumpRoom(live, around)
        val conversation = MatrixConversation(backgroundScope, room, at = "\$old", resume = true)

        val opened = conversation.state.first { !it.loading }
        assertEquals(listOf("Earlier", "Unread"), opened.rows.messages.map { it.body })
        assertEquals("\$next", opened.firstUnread)
        assertTrue(opened.startsAtUnread)
        assertNull(opened.highlight)
        assertTrue(opened.focused)
        conversation.close()
    }

    @Test fun anUnreadConversationWhoseReadMarkerIsOnAThreadReplyOpensLive() = runTest {
        // Around a thread reply the SDK shows only its thread, so the channel stays live, as on the Mac.
        val live = ConversationTimeline(listOf(conversationItem("new", "\$new", "Latest")))
        val room = JumpRoom(live, ConversationTimeline(listOf(conversationItem("reply", "\$reply", "In a thread"))),
            threadRoots = mapOf("\$reply" to "\$root"))
        val conversation = MatrixConversation(backgroundScope, room, at = "\$reply", resume = true)

        assertEquals(listOf("Latest"), conversation.state.first { !it.loading }.rows.messages.map { it.body })
        assertEquals(listOf<TimelineFocus>(TimelineFocus.Live(true)), room.focuses)
        conversation.close()
    }

    // capability: thread.open
    @Test fun aThreadShowsTheRootTheChannelHadAtOnceAndKeepsItsRowWhenTheThreadLoadsIt() = runTest {
        val root = ConversationMessage("channel-row", "\$root", "@mira:example.org", "Mira Chen", "Plan?", null,
            1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "MC", 0, grouped = true)
        val timeline = ConversationTimeline(emptyList())
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline), threadRoot = "\$root", root = root)

        val first = conversation.state.value
        assertFalse("The root needs no wait", first.loading)
        assertEquals(listOf("\$root"), first.rows.map { (it as ConversationMessage).eventId })
        assertFalse("The root starts the thread, so it shows its sender", first.rows.messages.single().grouped)

        runCurrent()
        // The day's divider sits above the root in the thread's timeline; above the root, nothing shows.
        timeline.emit(listOf(TimelineDiff.Reset(listOf(dateDivider("day", 1_700_000_000_000u),
            conversationItem("thread-root", "\$root", "Plan?"), conversationItem("reply", "\$reply", "Yes")))))
        val loaded = conversation.state.first { it.rows.size == 2 }
        assertEquals("The root keeps its row, so it never redraws", listOf(first.rows.single().id, "reply"), loaded.rows.map { it.id })
        conversation.close()
    }
}

private class JumpRoom(private val live: Timeline, private val around: Timeline,
    private val threadRoots: Map<String, String> = emptyMap()) : Room(NoHandle) {
    val focuses = mutableListOf<TimelineFocus>()
    override suspend fun loadOrFetchEvent(eventId: String): TimelineEvent = object : TimelineEvent(NoHandle) {
        override fun threadRootEventId(): String? = threadRoots[eventId]
    }
    var aroundFailure: Exception? = null
    override suspend fun setUnreadFlag(newValue: Boolean) = Unit
    override fun ownUserId(): String = "@me:example.org"
    override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline {
        focuses += configuration.focus
        if (configuration.focus is TimelineFocus.Event) aroundFailure?.let { throw it }
        return if (configuration.focus is TimelineFocus.Event) around else live
    }
}

private class ConversationRoom(private val value: Timeline) : Room(NoHandle) {
    var configuration: TimelineConfiguration? = null
    var markedUnread = true
    val sendQueueEnabled = CompletableDeferred<Boolean>()
    override fun enableSendQueue(enable: Boolean) { sendQueueEnabled.complete(enable) }
    override fun ownUserId(): String = "@me:example.org"
    override suspend fun setUnreadFlag(newValue: Boolean) { markedUnread = newValue }
    override suspend fun timeline(): Timeline = value
    override suspend fun matrixToEventPermalink(eventId: String): String = "https://matrix.to/#/!design:example.org/$eventId"
    var openFailure: Exception? = null
    override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline {
        openFailure?.let { throw it }
        this.configuration = configuration
        return value
    }
}

private class ConversationTimeline(private val cached: List<TimelineItem>) : Timeline(NoHandle) {
    private var listener: TimelineListener? = null
    val page = CompletableDeferred<Boolean>()
    val pageStarted = CompletableDeferred<Unit>()
    val pageCancelled = CompletableDeferred<Unit>()
    val listenerCancelled = CompletableDeferred<Unit>()
    val receipts = Channel<Pair<ReceiptType, String>>(Channel.UNLIMITED)
    val submissions = Channel<ConversationContent>(Channel.UNLIMITED)
    val sendResults = Channel<Result<SendHandle>>(Channel.UNLIMITED)
    val retried = Channel<EventOrTransactionId>(Channel.UNLIMITED)
    val aborted = Channel<EventOrTransactionId>(Channel.UNLIMITED)
    override suspend fun retrySend(itemId: EventOrTransactionId, target: SendTarget): Boolean { retried.send(itemId); return true }
    override suspend fun abortSend(itemId: EventOrTransactionId, target: SendTarget): Boolean { aborted.send(itemId); return true }
    val reactions = Channel<Pair<EventOrTransactionId, String>>(Channel.UNLIMITED)
    var reactionAdded = true
    override suspend fun toggleReaction(itemId: EventOrTransactionId, key: String): Boolean { reactions.send(itemId to key); return reactionAdded }
    val redacted = Channel<EventOrTransactionId>(Channel.UNLIMITED)
    var redactFailure: Exception? = null
    override suspend fun redactEvent(eventOrTransactionId: EventOrTransactionId, reason: String?) {
        redactFailure?.let { throw it }
        redacted.send(eventOrTransactionId)
    }
    val pins = Channel<Pair<String, Boolean>>(Channel.UNLIMITED)
    var pinFailure: Exception? = null
    override suspend fun pinEvent(eventId: String): Boolean {
        pinFailure?.let { throw it }
        pins.send(eventId to true)
        return true
    }
    override suspend fun unpinEvent(eventId: String): Boolean {
        pinFailure?.let { throw it }
        pins.send(eventId to false)
        return true
    }
    override suspend fun getEventTimelineItemByEventId(eventId: String): EventTimelineItem =
        checkNotNull(cached.firstNotNullOfOrNull { item -> item.asEvent()?.takeIf {
            (it.eventOrTransactionId as? EventOrTransactionId.EventId)?.eventId == eventId } })
    val fetched = Channel<String>(Channel.UNLIMITED)
    override suspend fun fetchDetailsForEvent(eventId: String) { fetched.send(eventId) }
    override suspend fun addListener(listener: TimelineListener): TaskHandle {
        this.listener = listener
        listener.onUpdate(listOf(TimelineDiff.Reset(cached)))
        return object : TaskHandle(NoHandle) { override fun cancel() { listenerCancelled.complete(Unit) } }
    }
    var pageFailure: Exception? = null
    var pages = 0
    override suspend fun paginateForwards(numEvents: UShort): Boolean = true
    override suspend fun paginateBackwards(numEvents: UShort): Boolean {
        pages++
        pageStarted.complete(Unit)
        pageFailure?.let { throw it }
        return try { page.await() } finally { pageCancelled.complete(Unit) }
    }
    var receiptFailure: Exception? = null
    override suspend fun sendReadReceipt(receiptType: ReceiptType, eventId: String) {
        receiptFailure?.let { throw it }
        receipts.send(receiptType to eventId)
    }
    fun emit(diff: List<TimelineDiff>) { listener?.onUpdate(diff) }
    override fun createMessageContent(msgType: MessageType): RoomMessageEventContentWithoutRelation = ConversationContent(msgType)
    override suspend fun send(msg: RoomMessageEventContentWithoutRelation): SendHandle {
        submissions.send(msg as ConversationContent)
        return sendResults.receive().getOrThrow()
    }
    val replies = Channel<String>(Channel.UNLIMITED)
    override suspend fun sendReply(msg: RoomMessageEventContentWithoutRelation, eventId: String): SendHandle {
        replies.send(eventId)
        return send(msg)
    }
    val attachments = Channel<Pair<UploadParameters, AttachmentKind>>(Channel.UNLIMITED)
    override fun sendAttachment(params: UploadParameters, attachment: AttachmentKind): SendAttachmentJoinHandle {
        attachments.trySend(params to attachment)
        return object : SendAttachmentJoinHandle(NoHandle) {
            override suspend fun join() = Unit
            override fun cancel() = Unit
        }
    }
    val edits = Channel<Pair<EventOrTransactionId, EditedContent>>(Channel.UNLIMITED)
    var editFailure: Exception? = null
    override suspend fun edit(eventOrTransactionId: EventOrTransactionId, newContent: EditedContent) {
        editFailure?.let { throw it }
        edits.send(eventOrTransactionId to newContent)
    }
}

private class ConversationContent(val type: MessageType) : RoomMessageEventContentWithoutRelation(NoHandle) {
    var mentions: Mentions? = null
    override fun withMentions(mentions: Mentions): RoomMessageEventContentWithoutRelation {
        this.mentions = mentions
        return this
    }
}

private fun conversationItem(
    stableId: String,
    eventId: String,
    body: String,
    local: Boolean = false,
    sendState: EventSendState? = if (local) EventSendState.NotSentYet(null) else null,
    content: TimelineItemContent? = null,
    reactions: List<Reaction> = emptyList(),
    sender: String = "@mira:example.org",
    timestamp: ULong = 1_700_000_000_000u,
    editable: Boolean = false,
    editState: EventSendState? = null,
    deleting: Boolean = false,
    onMap: () -> Unit = {},
): TimelineItem {
    val event = EventTimelineItem(
        isRemote = !local,
        eventOrTransactionId = if (local) EventOrTransactionId.TransactionId(eventId) else EventOrTransactionId.EventId(eventId),
        sender = sender,
        senderProfile = ProfileDetails.Ready(if (sender == "@mira:example.org") "Mira Chen" else "Sam Okafor", false, null, null, null),
        forwarder = null, forwarderProfile = null, isOwn = editable, isEditable = editable,
        content = content ?: TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)),
            null, null, null,
        )),
        reactions = reactions, eventTypeRaw = "m.room.message", timestamp = timestamp,
        localSendState = sendState, editSendState = editState,
        redactionSendState = if (deleting) EventSendState.NotSentYet(null) else null, localCreatedAt = null,
        readReceipts = emptyMap(), origin = null, canBeRepliedTo = true,
        lazyProvider = object : LazyTimelineItemProvider(NoHandle) {},
    )
    return object : TimelineItem(NoHandle) {
        override fun uniqueId(): TimelineUniqueId = TimelineUniqueId(stableId)
        override fun asEvent(): EventTimelineItem = event.also { onMap() }
    }
}

private fun readMarker() = object : TimelineItem(NoHandle) {
    override fun uniqueId(): TimelineUniqueId = TimelineUniqueId("read-marker")
    override fun asEvent(): EventTimelineItem? = null
    override fun asVirtual(): VirtualTimelineItem = VirtualTimelineItem.ReadMarker
}

private fun dateDivider(stableId: String, timestamp: ULong) = object : TimelineItem(NoHandle) {
    override fun uniqueId(): TimelineUniqueId = TimelineUniqueId(stableId)
    override fun asEvent(): EventTimelineItem? = null
    override fun asVirtual(): VirtualTimelineItem = VirtualTimelineItem.DateDivider(timestamp)
}

private val List<ConversationRow>.messages get() = filterIsInstance<ConversationMessage>()
