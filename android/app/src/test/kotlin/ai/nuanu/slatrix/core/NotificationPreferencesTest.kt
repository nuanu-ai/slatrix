package ai.nuanu.slatrix.core

import android.app.Application
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.NotificationSettings
import org.matrix.rustcomponents.sdk.RoomNotificationMode
import org.matrix.rustcomponents.sdk.RoomNotificationMode.ALL_MESSAGES
import org.matrix.rustcomponents.sdk.RoomNotificationMode.MENTIONS_AND_KEYWORDS_ONLY
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class NotificationPreferencesTest {
    private val alex = "@alex:example.org"

    /** The account's default push rules, keyed by encrypted and one-to-one. */
    private class Rules(vararg modes: Pair<Pair<Boolean, Boolean>, RoomNotificationMode>) : NotificationSettings(NoHandle) {
        val modes = mutableMapOf(*modes)
        override suspend fun getDefaultRoomNotificationMode(isEncrypted: Boolean, isOneToOne: Boolean) = modes.getValue(isEncrypted to isOneToOne)
        override suspend fun setDefaultRoomNotificationMode(isEncrypted: Boolean, isOneToOne: Boolean, mode: RoomNotificationMode) {
            modes[isEncrypted to isOneToOne] = mode
        }
    }

    private fun everything(mode: RoomNotificationMode) = Rules((true to true) to mode, (false to true) to mode, (true to false) to mode, (false to false) to mode)

    // capability: notifications.defaults
    @Test fun eachChoiceSetsTheAccountsDefaultsForDirectMessagesAndGroups() = runTest {
        val context = RuntimeEnvironment.getApplication()
        val rules = everything(ALL_MESSAGES)
        assertEquals(NotifyAbout.All, NotificationPreferences(context, alex).notifyAbout(rules))

        NotificationPreferences(context, alex).setNotifyAbout(rules, NotifyAbout.DirectAndMentions)
        assertEquals(mapOf((true to true) to ALL_MESSAGES, (false to true) to ALL_MESSAGES,
            (true to false) to MENTIONS_AND_KEYWORDS_ONLY, (false to false) to MENTIONS_AND_KEYWORDS_ONLY), rules.modes)
        assertEquals(NotifyAbout.DirectAndMentions, NotificationPreferences(context, alex).notifyAbout(rules))

        NotificationPreferences(context, alex).setNotifyAbout(rules, NotifyAbout.All)
        assertEquals(everything(ALL_MESSAGES).modes, rules.modes)
    }

    // capability: notifications.defaults
    @Test fun nothingSilencesThisPhoneAndLeavesTheAccountsRulesForItsOtherDevices() = runTest {
        val context = RuntimeEnvironment.getApplication()
        val rules = everything(MENTIONS_AND_KEYWORDS_ONLY).apply { modes[true to true] = ALL_MESSAGES; modes[false to true] = ALL_MESSAGES }
        val before = rules.modes.toMap()

        NotificationPreferences(context, alex).setNotifyAbout(rules, NotifyAbout.None)
        assertEquals(before, rules.modes)
        assertEquals(NotifyAbout.None, NotificationPreferences(context, alex).notifyAbout(rules))
        assertEquals("Another account on this phone still notifies", NotifyAbout.DirectAndMentions,
            NotificationPreferences(context, "@sam:example.org").notifyAbout(rules))

        NotificationPreferences(context, alex).setNotifyAbout(rules, NotifyAbout.DirectAndMentions)
        assertEquals(NotifyAbout.DirectAndMentions, NotificationPreferences(context, alex).notifyAbout(rules))
    }

    @Test fun rulesSetElsewhereThatMatchNoChoiceSelectNoChoice() = runTest {
        val rules = everything(ALL_MESSAGES).apply { modes[true to false] = MENTIONS_AND_KEYWORDS_ONLY }
        assertNull(NotificationPreferences(RuntimeEnvironment.getApplication(), alex).notifyAbout(rules))
    }
}
