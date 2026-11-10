package ai.nuanu.slatrix

import org.matrix.rustcomponents.sdk.MediaSource
import org.matrix.rustcomponents.sdk.NoHandle

/** A plain SDK source, whose JSON identity keeps the same URL. */
internal class TestMediaSource(private val address: String) : MediaSource(NoHandle) {
    override fun url(): String = address
    override fun toJson(): String = "\"$address\""
}
