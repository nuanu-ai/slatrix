import Foundation
import MatrixRustSDK

final class FakeCancellableHandle: TaskHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    override func cancel() { lock.withLock { cancelled = true } }
}

func roomInfo(
    id: String, name: String? = nil, membership: Membership = .joined, isSpace: Bool = false, unread: UInt64 = 0
) -> RoomInfo {
    RoomInfo(
        id: id, encryptionState: .encrypted, creators: nil, displayName: name ?? id, rawName: name, topic: nil,
        avatarUrl: nil, isDirect: false, isDm: false, isPublic: false, isSpace: isSpace, successorRoom: nil,
        isFavourite: false, isLowPriority: false, canonicalAlias: nil, alternativeAliases: [], membership: membership,
        inviter: nil, heroes: [], activeMembersCount: 2, invitedMembersCount: 0, joinedMembersCount: 2,
        activeServiceMembersCount: 0, serviceMembers: [], highlightCount: 0, notificationCount: unread,
        cachedUserDefinedNotificationMode: nil, hasRoomCall: false, activeRoomCallParticipants: [],
        activeRoomCallConsensusIntent: .none, isMarkedUnread: false, numUnreadMessages: unread,
        numUnreadNotifications: unread, numUnreadMentions: 0, fullyReadEventId: nil, pinnedEventIds: [],
        joinRule: nil, historyVisibility: .joined, powerLevels: nil, roomVersion: "10", privilegedCreatorsRole: false)
}

final class FakeRoom: Room, @unchecked Sendable {
    private let lock = NSLock()
    private let identifier: String
    private var current: RoomInfo?
    private var listeners: [RoomInfoListener] = []
    private var subscriptions: [FakeCancellableHandle] = []
    private var reads = 0
    let infoGate = Gate()
    /// Simulates a busy account: every read reports another change to this room.
    var changesOnEveryRead = false
    var infoReads: Int { lock.withLock { reads } }
    var handles: [FakeCancellableHandle] { lock.withLock { subscriptions } }

    /// `info == nil` makes `roomInfo()` throw.
    init(_ info: RoomInfo?, id: String? = nil) {
        identifier = id ?? info?.id ?? "!failing:example.org"
        current = info
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    var info: RoomInfo? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    var memberList: RoomMembersIterator?
    override func id() -> String { identifier }
    override func members() async throws -> RoomMembersIterator {
        guard let memberList else { throw ClientError.Generic(msg: "fixture members failed", details: nil) }
        return memberList
    }
    override func isEncrypted() async -> Bool { true }
    override func getPowerLevels() async throws -> RoomPowerLevels {
        throw ClientError.Generic(msg: "fixture has no power levels", details: nil)
    }
    override func membership() -> Membership { info?.membership ?? .joined }
    override func roomInfo() async throws -> RoomInfo {
        lock.withLock { reads += 1 }
        await infoGate.wait()
        guard let info else { throw ClientError.Generic(msg: "fixture room info failed", details: nil) }
        if changesOnEveryRead { notifyInfoChanged() }
        return info
    }
    override func subscribeToRoomInfoUpdates(listener: RoomInfoListener) -> TaskHandle {
        let handle = FakeCancellableHandle(noHandle: .init())
        lock.withLock {
            listeners.append(listener)
            subscriptions.append(handle)
        }
        return handle
    }
    func notifyInfoChanged() {
        let (callbacks, value) = lock.withLock { (listeners, current) }
        if let value { for item in callbacks { item.call(roomInfo: value) } }
    }
}

final class FakeSpaceService: SpaceService, @unchecked Sendable {
    var parents: [String: [String]] = [:]
    /// Every room whose parents were asked for.
    let lookups = Recorder<String>()
    var roomLists: [String: SpaceRoomList] = [:]
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func topLevelJoinedSpaces() async -> [SpaceRoom] { [] }
    override func joinedParentIdsOfChild(childId: String) async throws -> [String] {
        lookups.append(childId)
        return parents[childId] ?? []
    }
    override func spaceRoomList(spaceId: String) async throws -> SpaceRoomList {
        guard let list = roomLists[spaceId] else { throw ClientError.Generic(msg: "unknown space", details: nil) }
        return list
    }
}

final class FakeClient: Client, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Room] = []
    let spaces = FakeSpaceService()
    /// Whether each `rooms()` call ran on the main thread.
    let roomsOnMainThread = Recorder<Bool>()
    init(rooms: [Room] = []) {
        list = rooms
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    var roomList: [Room] {
        get { lock.withLock { list } }
        set { lock.withLock { list = newValue } }
    }
    override func rooms() -> [Room] {
        roomsOnMainThread.append(Thread.isMainThread)
        return roomList
    }
    override func getRoom(roomId: String) throws -> Room? { roomList.first { $0.id() == roomId } }
    override func spaceService() async -> SpaceService { spaces }
    override func addRecentEmoji(emoji: String) async throws {}

    private var downloadCount = 0
    var downloads: Int { lock.withLock { downloadCount } }
    override func getMediaFile(
        mediaSource: MediaSource, filename: String?, mimeType: String, useCache: Bool, tempDir: String?
    ) async throws -> MediaFileHandle {
        lock.withLock { downloadCount += 1 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-media-" + UUID().uuidString)
        try Data("downloaded".utf8).write(to: url)
        return FakeMediaFile(url)
    }

    /// What every thumbnail request answers, once `thumbnails` lets it through.
    var thumbnail = Data()
    let thumbnails = Gate()
    override func getMediaThumbnail(mediaSource: MediaSource, width: UInt64, height: UInt64) async throws -> Data {
        await thumbnails.wait()
        return thumbnail
    }

    /// The whole file from the media store, which holds what the send queue sends; nil when it isn't there.
    var stored: Data?
    override func getMediaContent(mediaSource: MediaSource) async throws -> Data {
        guard let stored else { throw CancellationError() }
        return stored
    }
}

final class FakeMediaFile: MediaFileHandle, @unchecked Sendable {
    private let url: URL
    init(_ url: URL) {
        self.url = url
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func path() throws -> String { url.path }
    deinit { try? FileManager.default.removeItem(at: url) }
}

func roomMember(_ id: String, name: String? = nil, membership: MembershipState = .join) -> RoomMember {
    RoomMember(
        userId: id, displayName: name, avatarUrl: nil, status: nil, call: nil, membership: membership,
        isNameAmbiguous: false, powerLevel: .value(value: 0), isIgnored: false, suggestedRoleForPowerLevel: .creator,
        membershipChangeReason: nil, isServiceMember: false)
}
