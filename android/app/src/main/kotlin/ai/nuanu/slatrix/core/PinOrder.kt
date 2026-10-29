package ai.nuanu.slatrix.core

object PinOrder {
    fun <T> arrange(pinned: List<String>, items: List<T>, id: (T) -> String?): List<T> = items

    fun note(total: Int): String? = null
}
