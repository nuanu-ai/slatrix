package ai.nuanu.slatrix.core

/**
 * Slack's "Also send to #channel" for a thread reply: the channel gets a rich reply to it without rel_type m.thread,
 * which MSC3440 lets clients show in the main timeline to advertise a thread message. The rule's cases are in
 * spec/send-to-channel.json.
 */
object ChannelCopy {
    /** The copy's event content as JSON. Its m.mentions is empty, so whoever the reply mentions hears once, from the thread. */
    fun content(message: ComposerMessage, replyTo: String): String = buildString {
        append("""{"msgtype":"m.text","body":""").append(jsonString(message.body))
        message.html?.let { append(""","format":"org.matrix.custom.html","formatted_body":""").append(jsonString(it)) }
        append(""","m.mentions":{},"m.relates_to":{"m.in_reply_to":{"event_id":""").append(jsonString(replyTo)).append("}}}")
    }
}

/** [text] as a JSON string literal. */
internal fun jsonString(text: String): String = buildString {
    append('"')
    for (char in text) when {
        char == '"' || char == '\\' -> append('\\').append(char)
        char < ' ' -> append("\\u%04x".format(char.code))
        else -> append(char)
    }
    append('"')
}
