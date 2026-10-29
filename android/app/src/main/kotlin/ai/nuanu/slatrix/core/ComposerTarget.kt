package ai.nuanu.slatrix.core

/** What the next send does besides posting: quote a message in a reply, or replace your own. */
sealed interface ComposerTarget {
    val eventId: String

    data class Reply(override val eventId: String, val senderName: String, val body: String) : ComposerTarget

    /** [html] is the message's formatted body, which keeps its mention pills. */
    data class Edit(override val eventId: String, val body: String, val html: String? = null) : ComposerTarget

    companion object {
        /** Null for a message that hasn't reached the server or was deleted. */
        fun reply(message: ConversationMessage): Reply? =
            message.sentEventId?.let { Reply(it, message.senderName, message.body) }

        fun edit(message: ConversationMessage): Edit? =
            message.sentEventId?.takeIf { message.editable }?.let { Edit(it, message.body) }

        private val ConversationMessage.sentEventId
            get() = eventId.takeIf { sendState == MessageSendState.Sent && kind != MessageKind.Deleted }
    }
}
