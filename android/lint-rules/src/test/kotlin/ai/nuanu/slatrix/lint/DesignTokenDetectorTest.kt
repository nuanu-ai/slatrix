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

    @Test
    fun testInlineComposeColorUsesPackageExemptionAndAllowsRoleReferences() {
        lint().files(
            kotlin(
                """
                package androidx.compose.ui.graphics
                @JvmInline value class Color(val value: ULong) {
                    companion object { val White: Color get() = TODO() }
                }
                fun Color(value: Long): Color = TODO()
                fun Color(value: Int): Color = TODO()
                """,
            ),
            unitStub,
            kotlin(
                """
                package ai.nuanu.slatrix.ui.designsystem
                import androidx.compose.ui.graphics.Color
                import androidx.compose.ui.unit.dp
                import androidx.compose.ui.unit.sp
                import androidx.compose.ui.unit.em
                object AppColors {
                    val surface = Color(0xff112233)
                    val text = Color.White
                }
                object Spacing { val small = 8.dp }
                object Type { val body = 14.sp; val lineHeight = 1.2.em }
                """,
            ).to("src/ai/nuanu/slatrix/ui/designsystem/Tokens.kt"),
            kotlin(
                """
                package ai.nuanu.slatrix.ui.chat
                import androidx.compose.ui.graphics.Color
                import ai.nuanu.slatrix.ui.designsystem.AppColors
                import ai.nuanu.slatrix.ui.designsystem.Spacing
                import ai.nuanu.slatrix.ui.designsystem.Type
                val background = AppColors.surface
                val foreground = AppColors.text
                val spacing = Spacing.small
                val textSize = Type.body
                val lineHeight = Type.lineHeight
                val rawBackground = Color(0xff112233)
                val rawForeground = Color.White
                """,
            ).to("src/ai/nuanu/slatrix/ui/chat/DesignSystem.kt"),
        ).run().expectErrorCount(2)
    }

    @Test
    fun testRejectsEquivalentConstantSizesAndDirectDpConstruction() {
        lint().files(
            unitStub,
            kotlin(
                """
                package ai.nuanu.slatrix.ui.chat
                import androidx.compose.ui.unit.Dp
                import androidx.compose.ui.unit.dp
                val parenthesized = (12).dp
                val negative = (-4).dp
                val calculated = (2 * 6).dp
                val constructed = Dp(12f)
                """,
            ),
        ).run().expectErrorCount(4)
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
        @JvmInline value class Dp(val value: Float)
        class TextUnit(value: Float)
        val Int.dp: Dp get() = Dp(toFloat())
        val Int.sp: TextUnit get() = TextUnit(toFloat())
        val Double.em: TextUnit get() = TextUnit(toFloat())
        """,
    )
}
