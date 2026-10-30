package ai.nuanu.slatrix.core

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test
import org.matrix.rustcomponents.sdk.AttachmentKind
import org.matrix.rustcomponents.sdk.UploadSource

class VideoUploadTest {
    // capability: composer.video
    @Test fun `a video sends what every shared case says`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/video-upload.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            val name = case["name"].asString
            val video = case["video"].asJsonObject
            val shown = VideoUpload.shown(video.int("width"), video.int("height"), video["rotation"].asInt)
            val duration = video.long("durationMillis")
            val frame = case["posterFrame"].asJsonObject
            val poster = VideoUpload.posterSize(shown!!.first, shown.second)
            assertEquals(name, frame["atMillis"].asLong, VideoUpload.posterAt(duration))
            assertEquals(name, frame["width"].asInt to frame["height"].asInt, poster)

            val file = video["name"].asString
            val kind = VideoUpload.kind(OutgoingAttachment("/cache/upload/$file", file, video["mimetype"].asString,
                video["size"].asLong, shown.first, shown.second, duration,
                case.long("posterBytes")?.let { VideoPoster("/cache/upload/poster.jpg", poster.first, poster.second, it) }))
            // m.video and its info; the body is the file's own name, which the import keeps for the upload.
            val sent = case["sent"].asJsonObject
            assertEquals(name, "m.video", sent["msgtype"].asString)
            val info = (kind as AttachmentKind.Video).videoInfo
            assertEquals(name, sent["info"], JsonObject().apply {
                addProperty("w", info.width?.toLong())
                addProperty("h", info.height?.toLong())
                info.duration?.let { addProperty("duration", it.toMillis()) }
                addProperty("mimetype", info.mimetype)
                addProperty("size", info.size?.toLong())
                info.thumbnailInfo?.let { thumbnail ->
                    add("thumbnail_info", JsonObject().apply {
                        addProperty("w", thumbnail.width?.toLong())
                        addProperty("h", thumbnail.height?.toLong())
                        addProperty("mimetype", thumbnail.mimetype)
                        addProperty("size", thumbnail.size?.toLong())
                    })
                }
            })
            assertEquals(name, case.long("posterBytes") != null, kind.thumbnailSource == UploadSource.File("/cache/upload/poster.jpg"))
        }
    }

    private fun JsonObject.int(key: String) = get(key)?.takeUnless(JsonElement::isJsonNull)?.asInt
    private fun JsonObject.long(key: String) = get(key)?.takeUnless(JsonElement::isJsonNull)?.asLong
}
