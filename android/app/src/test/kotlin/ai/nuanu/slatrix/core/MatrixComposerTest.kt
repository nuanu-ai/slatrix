package ai.nuanu.slatrix.core

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.ComposerDraft
import org.matrix.rustcomponents.sdk.ComposerDraftType
import org.matrix.rustcomponents.sdk.MembershipState
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.PowerLevel
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.RoomMember
import org.matrix.rustcomponents.sdk.RoomMembersIterator
import org.matrix.rustcomponents.sdk.RoomPowerLevels

class MatrixComposerTest {
    // capability: composer.drafts
    @Test fun restoresDraftAndFlushesTheLastEditBeforeNavigation() = runTest {
        val room = ComposerRoom(ComposerDraft("Remember this", null, ComposerDraftType.NewMessage, emptyList()))
        val composer = MatrixComposer(backgroundScope, room) { true }
        assertEquals("Remember this", composer.state.first { !it.loading }.text)

        composer.edit("Finish tomorrow\nwith <details>")
        composer.close()
        val reopened = MatrixComposer(backgroundScope, room) { true }
        assertEquals("Finish tomorrow\nwith <details>", reopened.state.first { !it.loading }.text)
        reopened.close()
    }

    @Test fun typingIsSavedAfterAPauseAndSendingClearsTheStoredDraftAtOnce() = runTest {
        val room = ComposerRoom()
        val composer = MatrixComposer(backgroundScope, room) { true }
        composer.state.first { !it.loading }
        for (typed in listOf("H", "He", "Hel", "Hell")) {
            composer.edit(typed)
            advanceTimeBy(300)
            assertNull("Typing without a pause must not write the encrypted store", room.draft)
        }
        composer.edit("Hello")
        advanceTimeBy(1_000)
        assertEquals("Hello", room.draft?.plainText)

        composer.send()
        runCurrent()
        assertNull("A sent message must not come back as a draft", room.draft)
        composer.close()
    }

    @Test fun sendFailureKeepsTheDraftAndLaterSuccessPreservesAReeditedDraft() = runTest {
        val room = ComposerRoom()
        val submissions = Channel<ComposerMessage>(Channel.UNLIMITED)
        val results = Channel<Boolean>(Channel.UNLIMITED)
        val composer = MatrixComposer(backgroundScope, room) {
            submissions.send(it)
            results.receive()
        }
        composer.state.first { !it.loading }
        composer.edit("Hi @mira:example.org\n<tomorrow>")
        composer.send()
        runCurrent()
        assertTrue("Sending must remain visible until the SDK accepts the message", composer.state.value.sending)
        val outgoing = submissions.receive()
        assertEquals("Hi @mira\n<tomorrow>", outgoing.body)
        assertEquals(listOf("@mira:example.org"), outgoing.mentions)
        results.send(false)
        composer.state.first { !it.sending }
        assertNotNull(composer.state.value.error)
        assertEquals("Hi @mira:example.org\n<tomorrow>", composer.state.value.text)

        composer.retry()
        submissions.receive()
        composer.edit("A different draft")
        composer.edit("Hi @mira:example.org\n<tomorrow>")
        results.send(true)
        composer.state.first { !it.sending }
        assertEquals("Hi @mira:example.org\n<tomorrow>", composer.state.value.text)
        composer.close()
        val reopened = MatrixComposer(backgroundScope, room) { true }
        assertEquals("Hi @mira:example.org\n<tomorrow>", reopened.state.first { !it.loading }.text)
        reopened.send()
        assertEquals("", reopened.state.first { !it.sending }.text)
        reopened.close()
        val sent = MatrixComposer(backgroundScope, room) { true }
        assertEquals("", sent.state.first { !it.loading }.text)
        sent.close()
    }

    // capability: message.reply
    @Test fun aReplyGoesWithTheNextSendAndTheBarCanBeClosed() = runTest {
        val sent = Channel<ComposerMessage>(Channel.UNLIMITED)
        val composer = MatrixComposer(backgroundScope, ComposerRoom()) { sent.send(it); true }
        composer.state.first { !it.loading }
        val target = ComposerTarget.Reply("\$one", "Mira Chen", "Ship it?")
        composer.reply(target)
        composer.cancelTarget()
        composer.edit("Not a reply")
        composer.send()
        assertNull(sent.receive().target)

        composer.reply(target)
        composer.edit("Yes")
        composer.send()
        assertEquals(target, sent.receive().target)
        assertNull(composer.state.first { !it.sending }.target)
        composer.close()
    }

    // capability: message.edit
    @Test fun editingFillsTheComposerAndGivesTheDraftBackAfterwards() = runTest {
        val room = ComposerRoom(ComposerDraft("Half a thought", null, ComposerDraftType.NewMessage, emptyList()))
        val sent = Channel<ComposerMessage>(Channel.UNLIMITED)
        val composer = MatrixComposer(backgroundScope, room) { sent.send(it); true }
        composer.state.first { !it.loading }
        val target = ComposerTarget.Edit("\$one", "Shipped")
        composer.editMessage(target)
        assertEquals("Shipped", composer.state.value.text)
        composer.edit("Shipped today")
        advanceTimeBy(1_000)
        assertEquals("Editing never replaces the saved draft", "Half a thought", room.draft?.plainText)
        composer.send()
        val edit = sent.receive()
        assertEquals("Shipped today", edit.body)
        assertEquals(target, edit.target)
        assertEquals("Half a thought", composer.state.first { !it.sending }.text)
        assertNull(composer.state.value.target)

        composer.editMessage(target)
        composer.cancelTarget()
        assertEquals("Half a thought", composer.state.value.text)
        composer.close()
    }

    // capability: composer.mentions
    @Test fun aChosenMentionSendsAPillThatEditsAroundItAndTheDraftKeep() = runTest {
        val room = ComposerRoom()
        val sent = Channel<ComposerMessage>(Channel.UNLIMITED)
        val composer = MatrixComposer(backgroundScope, room) { sent.send(it); true }
        composer.state.first { !it.loading }
        composer.edit("Hi @mi")
        composer.mention(3, 6, MentionCandidate.Member(MentionPerson("@mira:example.org", "Mira Chen")))
        assertEquals("Hi @Mira Chen ", composer.state.value.text)
        composer.edit("Oh hi @Mira Chen ")
        composer.edit("Oh hi @Mira Chen, thanks")
        composer.close()

        val reopened = MatrixComposer(backgroundScope, room) { sent.send(it); true }
        assertEquals("Oh hi @Mira Chen, thanks", reopened.state.first { !it.loading }.text)
        reopened.send()
        val message = sent.receive()
        assertEquals("Oh hi @Mira Chen, thanks", message.body)
        assertEquals(listOf("@mira:example.org"), message.mentions)
        assertEquals("Oh hi <a href=\"https://matrix.to/#/@mira:example.org\">Mira Chen</a>, thanks", message.html)

        reopened.state.first { !it.sending }
        reopened.edit("@ro")
        reopened.mention(0, 3, MentionCandidate.Room)
        reopened.mention(6, 6, MentionCandidate.Member(MentionPerson("@sam:example.org", "Sam")))
        reopened.edit("@room @Sa")
        reopened.send()
        val broken = sent.receive()
        assertEquals("A pill edited inside turns back into text", emptyList<String>(), broken.mentions)
        assertTrue(broken.mentionsRoom)
        reopened.close()
    }

    @Test fun peopleToMentionLoadWithWhetherYouMayNotifyTheRoom() = runTest {
        val room = ComposerRoom()
        val composer = MatrixComposer(backgroundScope, room) { true }
        composer.state.first { !it.loading }
        composer.loadPeople()
        val people = composer.people.first { it != null }!!
        assertEquals(listOf(MentionPerson("@mira:example.org", "Mira Chen"), MentionPerson("@sam:example.org", "sam", "invite")),
            people.members)
        assertTrue(people.offersRoom)
        composer.close()
    }

    @Test fun storageFailuresRetryWithoutReplacingTheUnrestoredDraftOrSendingIt() = runTest {
        val room = ComposerRoom(ComposerDraft("Stored safely", null, ComposerDraftType.NewMessage, emptyList()))
        room.loadFailure = IllegalStateException("Store unavailable")
        val composer = MatrixComposer(backgroundScope, room) { error("A storage retry must not send") }
        composer.state.first { !it.loading }
        assertNotNull(composer.state.value.error)
        composer.edit("A placeholder must not replace the stored draft")

        room.loadFailure = null
        composer.retry()
        runCurrent()
        assertEquals("Stored safely", composer.state.value.text)
        assertNull(composer.state.value.error)

        room.saveFailure = IllegalStateException("Disk unavailable")
        composer.edit("Keep the pending edit")
        advanceTimeBy(1_000)
        assertNotNull(composer.state.value.error)
        assertEquals("Keep the pending edit", composer.state.value.text)
        room.saveFailure = null
        composer.retry()
        advanceTimeBy(1_000)
        assertNull(composer.state.value.error)
        composer.close()
        val reopened = MatrixComposer(backgroundScope, room) { true }
        assertEquals("Keep the pending edit", reopened.state.first { !it.loading }.text)
        reopened.close()
    }
}

private class ComposerRoom(var draft: ComposerDraft? = null) : Room(NoHandle) {
    var loadFailure: Exception? = null
    var saveFailure: Exception? = null
    override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? {
        loadFailure?.let { throw it }
        return draft
    }
    override suspend fun saveComposerDraft(draft: ComposerDraft, threadRoot: String?) {
        saveFailure?.let { throw it }
        this.draft = draft
    }
    override suspend fun clearComposerDraft(threadRoot: String?) { draft = null }
    override fun ownUserId(): String = "@me:example.org"
    override suspend fun members(): RoomMembersIterator {
        val chunks = ArrayDeque(listOf(listOf(member("@mira:example.org", "Mira Chen", MembershipState.Join)),
            listOf(member("@sam:example.org", null, MembershipState.Invite))))
        return object : RoomMembersIterator(NoHandle) {
            override fun len(): UInt = 2u
            override fun nextChunk(chunkSize: UInt): List<RoomMember>? = chunks.removeFirstOrNull()
        }
    }
    override suspend fun getPowerLevels(): RoomPowerLevels = object : RoomPowerLevels(NoHandle) {
        override fun canUserTriggerRoomNotification(userId: String): Boolean = userId == "@me:example.org"
    }
    private fun member(id: String, name: String?, membership: MembershipState) = RoomMember(id, name, null, null, null,
        membership, false, PowerLevel.Value(0), false, uniffi.matrix_sdk.RoomMemberRole.USER, null, false)
}
