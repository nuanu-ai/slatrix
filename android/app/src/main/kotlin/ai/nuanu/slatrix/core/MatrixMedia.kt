package ai.nuanu.slatrix.core

import java.io.File
import org.matrix.rustcomponents.sdk.Client

class MatrixMedia(private val client: Client, private val folder: File) {
    suspend fun picture(attachment: MessageAttachment, width: Int, height: Int): ByteArray? = null

    suspend fun file(attachment: MessageAttachment): File = folder
}
