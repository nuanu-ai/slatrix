package ai.nuanu.slatrix.push

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationTextTest {
    @Test fun aNotificationReadsAsInEverySharedCase() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/notification-text.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            fun text(key: String) = case[key].asString
            assertEquals(text("name"), text("title") to text("text"),
                NotificationText.message(text("room"), text("sender"), case["direct"].asBoolean, text("body")))
        }
    }
}
