package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.AndroidTheme
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.core.MatrixRooms
import ai.nuanu.slatrix.core.roomInfo
import ai.nuanu.slatrix.ui.account.SlatrixApp
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.LatestEventValue
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.RawAccountDataListener
import org.matrix.rustcomponents.sdk.RefusedChange
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.RoomInfo
import org.matrix.rustcomponents.sdk.RoomInfoListener
import org.matrix.rustcomponents.sdk.RoomList
import org.matrix.rustcomponents.sdk.RoomListDynamicEntriesController
import org.matrix.rustcomponents.sdk.RoomListEntriesDynamicFilterKind
import org.matrix.rustcomponents.sdk.RoomListEntriesListener
import org.matrix.rustcomponents.sdk.RoomListEntriesWithDynamicAdaptersResult
import org.matrix.rustcomponents.sdk.RoomListService
import org.matrix.rustcomponents.sdk.RoomListServiceState
import org.matrix.rustcomponents.sdk.RoomListServiceStateListener
import org.matrix.rustcomponents.sdk.SendQueueRoomUpdateListener
import org.matrix.rustcomponents.sdk.SpaceRoom
import org.matrix.rustcomponents.sdk.SpaceService
import org.matrix.rustcomponents.sdk.SyncService
import org.matrix.rustcomponents.sdk.SyncServiceBuilder
import org.matrix.rustcomponents.sdk.SyncServiceState
import org.matrix.rustcomponents.sdk.SyncServiceStateObserver
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.TypingNotificationsListener
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-notnight-420dpi")
class SlatrixAppThemeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    // capability: app.themes
    @Test fun switchingWorkspacesInConnectedSlatrixAppSwitchesRenderedTheme() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        try { WorkManager.getInstance(context) } catch (_: IllegalStateException) {
            WorkManager.initialize(context, Configuration.Builder().build())
        }
        val harborId = "!harbor:example.org"
        val studioId = "!studio:example.org"
        val userId = "@alex:example.org"

        val prefs = AppearancePreferences(context)
        prefs.darkMode = false
        prefs.theme = AndroidTheme.Jade
        prefs.setWorkspaceTheme(harborId, AndroidTheme.Aubergine, userId = userId)

        val harborSpace = FakeRoom(roomInfo(harborId, "Harbor", space = true))
        val studioSpace = FakeRoom(roomInfo(studioId, "Studio Nine", space = true))
        val designChannel = FakeRoom(roomInfo("!design:example.org", "design"))
        val generalChannel = FakeRoom(roomInfo("!general:example.org", "general"))
        val client = FakeClient(
            user = userId,
            roomList = listOf(harborSpace, studioSpace, designChannel, generalChannel),
            parents = mapOf(
                "!design:example.org" to listOf(harborId),
                "!general:example.org" to listOf(studioId),
            ),
        )
        val scope = CoroutineScope(SupervisorJob())
        val rooms = MatrixRooms(scope, client)
        try {
            lateinit var view: View
            compose.setContent {
                view = LocalView.current
                SlatrixApp(
                    state = AccountState.Connected(client, userId),
                    onSelectHomeserver = {},
                    onSignIn = { _, _ -> },
                    onSignInWithBrowser = {},
                    onRestore = {},
                    onSignOut = {},
                    onCancel = {},
                    identity = null,
                    rooms = rooms,
                    workspace = null,
                )
            }
            compose.waitUntil(5_000) {
                compose.onAllNodes(hasText("Harbor")).fetchSemanticsNodes().isNotEmpty()
            }

            fun fabAccentPixel(): Int {
                compose.waitForIdle()
                val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
                val bounds = compose.onNodeWithContentDescription("New message").fetchSemanticsNode().boundsInRoot
                val x = (bounds.left + bounds.width * 0.2f).toInt()
                val y = (bounds.top + bounds.height * 0.5f).toInt()
                return bitmap.getPixel(x, y)
            }

            val expectedAubergine = DesignTokens.colors(AndroidTheme.Aubergine, dark = false).getValue("accentFill").toArgb()
            val expectedJade = DesignTokens.colors(AndroidTheme.Jade, dark = false).getValue("accentFill").toArgb()
            assertEquals("Harbor uses its Aubergine workspace override", expectedAubergine, fabAccentPixel())

            compose.onNodeWithContentDescription("Switch workspace").performClick()
            compose.onNodeWithText("Studio Nine").performClick()
            compose.waitUntil(5_000) {
                compose.onAllNodes(hasText("Studio Nine")).fetchSemanticsNodes().isNotEmpty()
            }
            assertEquals("Studio Nine uses the global Jade fallback", expectedJade, fabAccentPixel())
        } finally {
            runBlocking { rooms.close() }
            scope.cancel()
        }
    }

    private class NoopHandle : TaskHandle(NoHandle) { override fun cancel() = Unit }

    private class FakeRoom(private val info: RoomInfo) : Room(NoHandle) {
        override fun id(): String = info.id
        override fun ownUserId(): String = "@alex:example.org"
        override suspend fun roomInfo(): RoomInfo = info
        override suspend fun latestEvent(): LatestEventValue = LatestEventValue.None
        override fun subscribeToRoomInfoUpdates(listener: RoomInfoListener): TaskHandle = NoopHandle()
        override fun subscribeToTypingNotifications(listener: TypingNotificationsListener): TaskHandle = NoopHandle()
        override fun isSendQueueEnabled(): Boolean = true
        override fun enableSendQueue(enable: Boolean) = Unit
    }

    private class FakeClient(
        private val user: String,
        private val roomList: List<Room>,
        private val parents: Map<String, List<String>>,
    ) : Client(NoHandle) {
        override fun userId(): String = user
        override suspend fun displayName(): String = "Alex Doe"
        override suspend fun cachedAvatarUrl(): String? = null
        override suspend fun avatarUrl(): String? = null
        override fun observeRawAccountDataEvent(eventType: String, listener: RawAccountDataListener): TaskHandle = NoopHandle()
        override suspend fun abortRefusedChanges(): List<RefusedChange> = emptyList()
        override suspend fun subscribeToSendQueueUpdates(listener: SendQueueRoomUpdateListener): TaskHandle = NoopHandle()
        override suspend fun enableAllSendQueues(enable: Boolean) = Unit
        override fun rooms(): List<Room> = roomList
        override fun getRoom(roomId: String): Room? = roomList.firstOrNull { it.id() == roomId }
        override suspend fun accountData(eventType: String): String? = null
        override suspend fun spaceService(): SpaceService = object : SpaceService(NoHandle) {
            override suspend fun topLevelJoinedSpaces(): List<SpaceRoom> = emptyList()
            override suspend fun joinedParentIdsOfChild(childId: String): List<String> = parents[childId].orEmpty()
        }
        override fun syncService(): SyncServiceBuilder = object : SyncServiceBuilder(NoHandle) {
            override fun withOfflineMode(): SyncServiceBuilder = this
            override suspend fun finish(): SyncService = object : SyncService(NoHandle) {
                private var stateListener: SyncServiceStateObserver? = null
                private var roomStateListener: RoomListServiceStateListener? = null
                override fun roomListService(): RoomListService = object : RoomListService(NoHandle) {
                    override fun state(listener: RoomListServiceStateListener): TaskHandle {
                        roomStateListener = listener
                        return NoopHandle()
                    }
                    override suspend fun allRooms(): RoomList = object : RoomList(NoHandle) {
                        override fun entriesWithDynamicAdapters(pageSize: UInt, listener: RoomListEntriesListener): RoomListEntriesWithDynamicAdaptersResult =
                            object : RoomListEntriesWithDynamicAdaptersResult(NoHandle) {
                                override fun entriesStream(): TaskHandle = NoopHandle()
                                override fun controller(): RoomListDynamicEntriesController = object : RoomListDynamicEntriesController(NoHandle) {
                                    override fun setFilter(kind: RoomListEntriesDynamicFilterKind): Boolean = true
                                }
                            }
                    }
                }
                override fun state(listener: SyncServiceStateObserver): TaskHandle {
                    stateListener = listener
                    return NoopHandle()
                }
                override suspend fun start() {
                    stateListener?.onUpdate(SyncServiceState.RUNNING)
                    roomStateListener?.onUpdate(RoomListServiceState.RUNNING)
                }
                override suspend fun stop() = Unit
            }
        }
    }
}
