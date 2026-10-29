package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class FileKindTest {
    // capability: message.file
    @Test fun `a file's kind and label match every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/file-kind.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            val name = case["name"].asString
            val mime = case["mime"].takeUnless { it.isJsonNull }?.asString
            val kind = FileKind.of(name, mime)
            assertEquals(name, case["kind"].asString to case["label"].asString, kind.token to kind.label(name))
        }
    }
}
