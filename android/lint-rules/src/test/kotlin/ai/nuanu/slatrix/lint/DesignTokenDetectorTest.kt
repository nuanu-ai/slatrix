package ai.nuanu.slatrix.lint

import com.android.tools.lint.checks.infrastructure.LintDetectorTest
import org.junit.Test

class DesignTokenDetectorTest : LintDetectorTest() {
    override fun getDetector() = DesignTokenDetector()
    override fun getIssues() = listOf(DesignTokenDetector.ISSUE)

    @Test
    fun testRejectsRawComposeColorsAndLiteralSizes() {
        lint().files(
            colorStub,
            unitStub,
            kotlin(
                """
                package ai.nuanu.slatrix.ui.chat
                import androidx.compose.ui.graphics.Color
                import androidx.compose.ui.unit.dp
                import androidx.compose.ui.unit.sp
                import androidx.compose.ui.unit.em

                val background = Color(0xff112233)
                val foreground = Color.White
                val spacing = 12.dp
                val textSize = 14.sp
                val lineHeight = 1.2.em
                """,
            ),
        ).run().expectErrorCount(5)
    }

    @Test
    fun testResolvesComposeFactoriesAndAliasesWithoutMatchingUnrelatedSymbols() {
        lint().files(
            colorStub,
            unitStub,
            kotlin(
                """
                package example
                class Color(value: Int) {
                    companion object { val White: Color get() = TODO() }
                }
                val Int.dp: Int get() = this
                """,
            ),
            kotlin(
                """
                package ai.nuanu.slatrix.ui.chat
                import androidx.compose.ui.graphics.Color as Ink
                import androidx.compose.ui.graphics.Color.Companion.White as Paper
                import androidx.compose.ui.unit.dp as gap
                import example.Color
                import example.dp

                val background = Ink(0x112233)
                val foreground = Paper
                val spacing = 8.gap
                val unrelatedColor = Color(42)
                val unrelatedWhite = Color.White
                val unrelatedSize = 5.dp
                val retryCount = 3
                """,
            ),
        ).run().expectErrorCount(3)
    }

    private val colorStub = kotlin(
        """
        package androidx.compose.ui.graphics
        class Color(value: Long) {
            companion object { val White: Color get() = TODO() }
        }
        fun Color(value: Int): Color = TODO()
        """,
    )

    private val unitStub = kotlin(
        """
        package androidx.compose.ui.unit
        class Dp(value: Float)
        class TextUnit(value: Float)
        val Int.dp: Dp get() = Dp(toFloat())
        val Int.sp: TextUnit get() = TextUnit(toFloat())
        val Double.em: TextUnit get() = TextUnit(toFloat())
        """,
    )
}
