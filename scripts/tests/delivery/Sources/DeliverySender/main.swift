import Foundation
import MatrixRustSDK

// A separate process lets the test kill the SDK with its real on-disk send queue open.
let arguments = CommandLine.arguments
let restoring = arguments[1] == "restore"
let url = arguments[2]
let roomID = arguments[3]
let store = arguments[4]
let client = try await ClientBuilder().homeserverUrl(url: url).slidingSyncVersionBuilder(versionBuilder: .native)
    .sessionPaths(dataPath: store + "/data", cachePath: store + "/cache").build()
let token = ProcessInfo.processInfo.environment["DELIVERY_TEST_TOKEN"]!
try await client.restoreSession(
    session: Session(
        accessToken: token, refreshToken: nil, userId: "@sender:test.invalid", deviceId: "SENDER",
        homeserverUrl: url, oauthData: nil, slidingSyncVersion: .native))
let room: Room
if restoring {
    guard let cached = try client.getRoom(roomId: roomID) else { fatalError("Missing room after restart") }
    room = cached
} else {
    room = try await client.joinRoomById(roomId: roomID)
}
let timeline = try await room.timeline()
let sync = try await client.syncService().withOfflineMode().finish()
await sync.start()
await client.enableAllSendQueues(enable: true)
for body in arguments.dropFirst(5) {
    _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: body))
}
print("ENQUEUED")
fflush(stdout)
withExtendedLifetime((client, sync, timeline)) { _ = readLine() }
