package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.AndroidTheme
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.ui.account.LivePreferencesScreen
import ai.nuanu.slatrix.ui.account.MessagePreview
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isHeading
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.TextUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class LiveProfileScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    // capability: app.appearance
    @Test fun aboutShowsTheVersionAndOpensTheLabAndTheSource() {
        val opened = mutableListOf<String>()
        compose.setContent {
            androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalUriHandler provides
                object : androidx.compose.ui.platform.UriHandler { override fun openUri(uri: String) { opened += uri } }) {
                SlatrixTheme { LivePreferencesScreen(false, null, AndroidTheme.Neutral, {}, {}, {}) }
            }
        }
        compose.onNode(hasText("Slatrix") and isHeading()).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Version ${ai.nuanu.slatrix.BuildConfig.VERSION_NAME}").assertIsDisplayed()
        compose.onNodeWithText("© 2026 Nuanu AI Lab").performScrollTo().performClick()
        compose.onNodeWithText("Source code on GitHub").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(listOf("https://nuanu.ai", "https://github.com/nuanu-ai/slatrix"), opened) }
    }

    @Test fun anAccountCanChooseDarkModeFromPreferences() {
        val mode = mutableStateOf<Boolean?>(null)
        compose.setContent {
            SlatrixTheme(dark = mode.value ?: false) {
                LivePreferencesScreen(mode.value ?: false, mode.value, AndroidTheme.Neutral, { mode.value = it }, {}, {})
            }
        }
        compose.onNodeWithText("System default").assertExists()
        compose.onNodeWithText("Color mode").performClick()
        compose.onNodeWithText("Dark").performClick()
        compose.runOnIdle { assertEquals(true, mode.value) }
        compose.onNodeWithText("Dark").assertExists()
    }

    // capability: app.appearance
    // capability: app.themes
    @Test fun preferencesSelectsAcrossNeutralAndColoredPalettesAndGoesBack() {
        val theme = mutableStateOf(AndroidTheme.Neutral)
        var returned = false
        compose.setContent {
            SlatrixTheme(theme = theme.value) {
                LivePreferencesScreen(false, null, theme.value, {}, { theme.value = it }, { returned = true })
            }
        }
        compose.onNodeWithText("All workspaces").assertDoesNotExist()
        compose.onNode(hasText("Neutral") and isSelectable()).performScrollTo().assertIsSelected()
        for (choice in listOf(AndroidTheme.MaterialYou, AndroidTheme.Sand, AndroidTheme.Aubergine, AndroidTheme.Jade, AndroidTheme.Ocean)) {
            compose.onNode(hasText(choice.label) and isSelectable()).performScrollTo().performClick().assertIsSelected()
            compose.runOnIdle { assertEquals(choice, theme.value) }
        }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertEquals(true, returned) }
    }

    // capability: app.themes
    @Test fun preferencesTogglesChatWallpaperAndIncreaseContrastIndependently() {
        val chatWallpaper = mutableStateOf(true)
        val increaseContrast = mutableStateOf(false)
        compose.setContent {
            SlatrixTheme(theme = AndroidTheme.Ocean, chatWallpaper = chatWallpaper.value, increaseContrast = increaseContrast.value) {
                LivePreferencesScreen(
                    dark = false,
                    darkOverride = null,
                    theme = AndroidTheme.Ocean,
                    onColorMode = {},
                    onTheme = {},
                    onBack = {},
                    chatWallpaper = chatWallpaper.value,
                    onChatWallpaper = { chatWallpaper.value = it },
                    increaseContrast = increaseContrast.value,
                    onIncreaseContrast = { increaseContrast.value = it },
                )
            }
        }
        compose.onNodeWithText("Chat wallpaper").performScrollTo().assertIsOn().performClick()
        compose.runOnIdle { assertEquals(false, chatWallpaper.value) }
        compose.onNodeWithText("Chat wallpaper").assertIsOff()

        compose.onNodeWithText("Increase contrast").performScrollTo().assertIsOff().performClick()
        compose.runOnIdle { assertEquals(true, increaseContrast.value) }
        compose.onNodeWithText("Increase contrast").assertIsOn()
    }

    // capability: app.themes
    @Test fun preferencesCanOverrideAndResetThemeForActiveWorkspace() {
        val globalTheme = mutableStateOf(AndroidTheme.Neutral)
        val harborOverride = mutableStateOf<AndroidTheme?>(null)
        val harborId = "!harbor:example.org"
        compose.setContent {
            SlatrixTheme(theme = harborOverride.value ?: globalTheme.value) {
                LivePreferencesScreen(
                    dark = false,
                    darkOverride = null,
                    theme = globalTheme.value,
                    onColorMode = {},
                    onTheme = { globalTheme.value = it },
                    onBack = {},
                    activeWorkspaceId = harborId,
                    activeWorkspaceName = "Harbor",
                    workspaceTheme = harborOverride.value,
                    onWorkspaceTheme = { id, choice ->
                        assertEquals(harborId, id)
                        harborOverride.value = choice
                    },
                )
            }
        }
        compose.onNode(hasText("All workspaces") and isSelectable()).performScrollTo().assertIsSelected()
        compose.onNodeWithText("Use default").assertDoesNotExist()

        // Switch scope to Harbor and pick Aubergine without altering the global theme.
        compose.onNode(hasText("Harbor") and isSelectable()).performScrollTo().performClick().assertIsSelected()
        compose.onNode(hasText("Aubergine") and isSelectable()).performScrollTo().performClick().assertIsSelected()
        compose.runOnIdle {
            assertEquals(AndroidTheme.Neutral, globalTheme.value)
            assertEquals(AndroidTheme.Aubergine, harborOverride.value)
        }

        // Reset back to the global default.
        compose.onNodeWithText("Use default").performScrollTo().performClick()
        compose.runOnIdle { assertNull(harborOverride.value) }
        compose.onNode(hasText("Neutral") and isSelectable()).performScrollTo().assertIsSelected()
        compose.onNodeWithText("Use default").assertDoesNotExist()
    }

    // capability: app.themes
    @Test fun preferencesOpensOnWorkspaceScopeWhenActiveWorkspaceAlreadyHasAnOverride() {
        val globalTheme = mutableStateOf(AndroidTheme.Sand)
        val harborOverride = mutableStateOf<AndroidTheme?>(AndroidTheme.Jade)
        compose.setContent {
            SlatrixTheme(theme = harborOverride.value ?: globalTheme.value) {
                LivePreferencesScreen(
                    dark = false,
                    darkOverride = null,
                    theme = globalTheme.value,
                    onColorMode = {},
                    onTheme = { globalTheme.value = it },
                    onBack = {},
                    activeWorkspaceId = "!harbor:example.org",
                    activeWorkspaceName = "Harbor",
                    workspaceTheme = harborOverride.value,
                    onWorkspaceTheme = { _, choice -> harborOverride.value = choice },
                )
            }
        }
        compose.onNode(hasText("Harbor") and isSelectable()).performScrollTo().assertIsSelected()
        compose.onNode(hasText("Jade") and isSelectable()).performScrollTo().assertIsSelected()
        compose.onNodeWithText("Use default").performScrollTo().assertIsDisplayed()

        // Switching to All workspaces shows the global theme and allows changing it without disturbing Harbor.
        compose.onNode(hasText("All workspaces") and isSelectable()).performScrollTo().performClick().assertIsSelected()
        compose.onNode(hasText("Sand") and isSelectable()).performScrollTo().assertIsSelected()
        compose.onNodeWithText("Harbor uses Jade").performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("Ocean") and isSelectable()).performScrollTo().performClick().assertIsSelected()
        compose.runOnIdle {
            assertEquals(AndroidTheme.Ocean, globalTheme.value)
            assertEquals(AndroidTheme.Jade, harborOverride.value)
        }
    }

    // capability: app.themes
    @Test fun lateArrivingWorkspaceNameStillStartsOnWorkspaceScopeWhenOverridden() {
        val workspaceName = mutableStateOf<String?>(null)
        val harborOverride = mutableStateOf<AndroidTheme?>(AndroidTheme.Aubergine)
        compose.setContent {
            SlatrixTheme(theme = harborOverride.value ?: AndroidTheme.Neutral) {
                LivePreferencesScreen(
                    dark = false,
                    darkOverride = null,
                    theme = AndroidTheme.Neutral,
                    onColorMode = {},
                    onTheme = {},
                    onBack = {},
                    activeWorkspaceId = "!harbor:example.org",
                    activeWorkspaceName = workspaceName.value,
                    workspaceTheme = harborOverride.value,
                    onWorkspaceTheme = { _, choice -> harborOverride.value = choice },
                )
            }
        }
        compose.onNodeWithText("All workspaces").assertDoesNotExist()
        compose.runOnIdle { workspaceName.value = "Harbor" }
        compose.onNode(hasText("Harbor") and isSelectable()).performScrollTo().assertIsSelected()
        compose.onNode(hasText("Aubergine") and isSelectable()).performScrollTo().assertIsSelected()
    }

    // capability: app.themes
    @Test @Config(qualifiers = "w320dp-h640dp-420dpi")
    fun narrowPhoneAtLargeTextSizeShowsAllPaletteAndScopeLabelsWithoutClipping() {
        compose.setContent {
            val baseDensity = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(baseDensity.density, fontScale = 2f)) {
                SlatrixTheme {
                    LivePreferencesScreen(
                        dark = false,
                        darkOverride = null,
                        theme = AndroidTheme.MaterialYou,
                        onColorMode = {},
                        onTheme = {},
                        onBack = {},
                        activeWorkspaceId = "!harbor:example.org",
                        activeWorkspaceName = "All workspaces North America",
                        workspaceTheme = null,
                        onWorkspaceTheme = { _, _ -> },
                    )
                }
            }
        }
        for (label in listOf("Material You", "Aubergine", "All workspaces", "All workspaces North America")) {
            val node = compose.onNode(hasText(label), useUnmergedTree = true).performScrollTo()
            val layouts = mutableListOf<TextLayoutResult>()
            node.fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action!!(layouts)
            val result = layouts.single()
            assertTrue(
                "'$label' clipped on 320dp at 200% font size: lines=${result.lineCount} width=${result.size.width}/${result.layoutInput.constraints.maxWidth} ovW=${result.didOverflowWidth} ovH=${result.didOverflowHeight}",
                !result.didOverflowWidth && !result.didOverflowHeight,
            )
        }
    }

    // capability: app.text-size
    @Test fun theTextSizeSliderGrowsMessageTextAndNothingElse() {
        val scale = mutableStateOf(1f)
        compose.setContent {
            SlatrixTheme(messageScale = scale.value) {
                LivePreferencesScreen(false, null, AndroidTheme.Neutral, {}, {}, {}, messageScale = scale.value, onMessageScale = { scale.value = it })
            }
        }
        val preview = fontSize(MessagePreview)
        val label = fontSize("Color mode")
        compose.onNodeWithContentDescription("Message text size").performScrollTo()
            .performSemanticsAction(SemanticsActions.SetProgress) { it(AppearancePreferences.MessageScales.lastIndex.toFloat()) }
        compose.runOnIdle { assertEquals(AppearancePreferences.MessageScales.last(), scale.value) }
        assertTrue("The preview grows", fontSize(MessagePreview) > preview)
        assertEquals("The rest of the app keeps its size", label, fontSize("Color mode"))
    }

    private fun fontSize(text: String): TextUnit {
        val layout = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(text).fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action!!(layout)
        return layout.single().layoutInput.style.fontSize
    }
}
