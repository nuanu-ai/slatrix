package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class SendToChannelTest {
    // capability: thread.send-to-channel
    @Test fun `the channel's copy of a thread reply matches every shared send case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/send-to-channel.json").readText()).asJsonObject
        for (item in spec["send"].asJsonArray) {
            val case = item.asJsonObject
            val content = ChannelCopy.content(ComposerFormat.message(case["draft"].asString), case["replyTo"].asString)
            assertEquals(case["name"].asString, case["content"], JsonParser.parseString(content))
        }
    }
}
