package ai.nuanu.slatrix.core

enum class TextStyle { Bold, Italic, Strike, Code, Underline }

/** Where a run sits among a message's blocks, which the row indents and decorates. */
data class MessageBlock(val quote: Int = 0, val list: Int = 0, val code: Boolean = false)

data class MessageRun(
    val text: String,
    val styles: Set<TextStyle> = emptySet(),
    val link: String? = null,
    /** The user ID a mention names, or "@room". */
    val mention: String? = null,
    val block: MessageBlock = MessageBlock(),
    /** A list item's "• " or "3. ". */
    val marker: Boolean = false,
)

object MessageFormat {
    fun render(body: String, html: String?): List<MessageRun> = listOf(MessageRun(body))
}
