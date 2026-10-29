import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Push rules as the SDK exposes them. Account defaults are keyed by "encrypted:oneToOne".
private final class Rules: NotificationSettings, @unchecked Sendable {
    private let lock = NSLock()
    private var roomRule = RoomNotificationSettings(mode: .mentionsAndKeywordsOnly, isDefault: true)
    private var defaultModes: [String: RoomNotificationMode] = [
        "true:true": .allMessages, "true:false": .mentionsAndKeywordsOnly, "false:true": .mentionsAndKeywordsOnly,
        "false:false": .allMessages,
    ]
    let writes = Recorder<String>()
    let roomReads = Recorder<String>()
    let defaultReads = Recorder<String>()
    let roomReadGate = Gate()
    let defaultReadGate = Gate()
    let writeGate = Gate()
    var failsRead = false
    var failsWrite = false
    /// With `failsWrite`, the write still changes the rules before it fails, like a half-applied multi-rule update.
    var appliesBeforeFailure = false
    /// The write is accepted but the rules read back unchanged until sync catches up.
    var lagsReadback = false
    /// The write leaves a default the app cannot interpret.
    var unreadableAfterWrite = false
    var onDefaultRead: (() -> Void)?

    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    var room: RoomNotificationSettings {
        get { lock.withLock { roomRule } }
        set { lock.withLock { roomRule = newValue } }
    }
    func defaultMode(encrypted: Bool, oneToOne: Bool) -> RoomNotificationMode? {
        lock.withLock { defaultModes["\(encrypted):\(oneToOne)"] }
    }
    private var applies: Bool { appliesBeforeFailure || (!failsWrite && !lagsReadback) }

    override func getRoomNotificationSettings(roomId: String, isEncrypted: Bool, isOneToOne: Bool) async throws
        -> RoomNotificationSettings
    {
        roomReads.append("\(isEncrypted):\(isOneToOne)")
        await roomReadGate.wait()
        if failsRead { throw MatrixServiceError.request("Fixture rules unavailable") }
        return room
    }
    override func getDefaultRoomNotificationMode(isEncrypted: Bool, isOneToOne: Bool) async -> RoomNotificationMode {
        onDefaultRead?()
        defaultReads.append("\(isEncrypted):\(isOneToOne)")
        await defaultReadGate.wait()
        return defaultMode(encrypted: isEncrypted, oneToOne: isOneToOne) ?? .mentionsAndKeywordsOnly
    }
    override func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws {
        writes.append("room:\(mode)")
        await writeGate.wait()
        if applies { room = RoomNotificationSettings(mode: mode, isDefault: false) }
        if failsWrite { throw MatrixServiceError.request("Fixture update failed after a rule may have changed") }
    }
    override func restoreDefaultRoomNotificationMode(roomId: String) async throws {
        writes.append("room:default")
        await writeGate.wait()
        if applies { room = RoomNotificationSettings(mode: .mentionsAndKeywordsOnly, isDefault: true) }
        if failsWrite { throw MatrixServiceError.request("Fixture reset failed") }
    }
    override func setDefaultRoomNotificationMode(isEncrypted: Bool, isOneToOne: Bool, mode: RoomNotificationMode)
        async throws
    {
        writes.append("default:\(isEncrypted):\(isOneToOne):\(mode)")
        await writeGate.wait()
        if applies {
            lock.withLock { defaultModes["\(isEncrypted):\(isOneToOne)"] = unreadableAfterWrite ? .mute : mode }
        }
        if failsWrite { throw MatrixServiceError.request("Fixture poll rule update failed") }
    }
}

private final class RulesClient: Client, @unchecked Sendable {
    let rules = Rules()
    let settingsGate = Gate()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func getNotificationSettings() async -> NotificationSettings {
        await settingsGate.wait()
        return rules
    }
}

private final class RulesRoom: Room, @unchecked Sendable {
    private let lock = NSLock()
    private var activeMembers: UInt64 = 2
    var joined = true
    var encryption: EncryptionState = .encrypted
    var failsEncryption = false
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    var members: UInt64 {
        get { lock.withLock { activeMembers } }
        set { lock.withLock { activeMembers = newValue } }
    }
    override func id() -> String { "!notifications:example.org" }
    override func membership() -> Membership { joined ? .joined : .left }
    override func latestEncryptionState() async throws -> EncryptionState {
        if failsEncryption { throw MatrixServiceError.request("Fixture encryption state unavailable") }
        return encryption
    }
    override func activeMembersCount() -> UInt64 { members }
}

@MainActor
struct RoomNotificationSettingsTests {
    private let client = RulesClient()
    private let room = RulesRoom()
    private var rules: Rules { client.rules }

    private func load(isCurrent: @escaping () -> Bool = { true }) async throws -> RoomNotificationSnapshot {
        try await RoomNotificationSettingsService.load(client: client, room: room) {
            guard isCurrent() else { throw CancellationError() }
        }
    }
    private func save(_ choice: RoomNotificationChoice, isCurrent: @escaping () -> Bool = { true }) async throws
        -> RoomNotificationSaveResult
    {
        try await RoomNotificationSettingsService.save(client: client, room: room, choice: choice) {
            guard isCurrent() else { throw CancellationError() }
        }
    }

    // capability: conversation.notifications
    @Test("An inherited setting shows the account default and what it resolves to, and opening it changes nothing")
    func inheritedSetting() async throws {
        let snapshot = try await load()
        #expect(snapshot.choice == .accountDefault)
        #expect(snapshot.effectiveChoice == .mentionsAndKeywords && snapshot.defaultChoice == .allMessages)
        #expect(snapshot.isEncrypted && snapshot.isOneToOne)
        #expect(rules.roomReads.all == ["true:true"])
        #expect(rules.writes.all.isEmpty)
    }

    // capability: conversation.notifications
    @Test("An explicit rule stays explicit even when it matches the default, and a group asks for group rules")
    func explicitGroupSetting() async throws {
        rules.room = RoomNotificationSettings(mode: .allMessages, isDefault: false)
        room.members = 3
        room.encryption = .notEncrypted
        let snapshot = try await load()
        #expect(snapshot.choice == .allMessages && snapshot.defaultChoice == .allMessages)
        #expect(!snapshot.isEncrypted && !snapshot.isOneToOne)
        #expect(rules.roomReads.all == ["false:false"])
    }

    @Test(
        "Each choice is saved and then shown as the SDK reads it back",
        arguments: [
            (RoomNotificationChoice.allMessages, "room:allMessages"),
            (.mentionsAndKeywords, "room:mentionsAndKeywordsOnly"), (.mute, "room:mute"),
            (.accountDefault, "room:default"),
        ])
    func savesChoice(choice: RoomNotificationChoice, write: String) async throws {
        if choice == .accountDefault { rules.room = RoomNotificationSettings(mode: .mute, isDefault: false) }
        let result = try await save(choice)
        #expect(result.requestedChoice == choice && result.snapshot?.choice == choice && result.warning == nil)
        #expect(rules.writes.all == [write])
    }

    @Test("A failed update reports the rules as they now are, warns that some may have changed, and is not retried")
    func failedUpdateReportsReadback() async throws {
        rules.failsWrite = true
        rules.appliesBeforeFailure = true
        do {
            _ = try await save(.mute)
            Issue.record("a failed update must be reported")
        } catch let failure as RoomNotificationSaveFailure {
            #expect(failure.snapshot?.choice == .mute && !failure.warning.isEmpty)
        }
        #expect(rules.writes.all == ["room:mute"])
    }

    @Test("An accepted update whose rules cannot be read back is a success that asks for a reload")
    func acceptedWithoutReadback() async throws {
        rules.failsRead = true
        let result = try await save(.allMessages)
        #expect(result.snapshot == nil && result.warning != nil && result.requestedChoice == .allMessages)
    }

    @Test("An accepted update that has not synced yet shows the synced rules with a warning, not the request")
    func acceptedButLagging() async throws {
        rules.lagsReadback = true
        rules.room = RoomNotificationSettings(mode: .mute, isDefault: false)
        let result = try await save(.mentionsAndKeywords)
        #expect(result.snapshot?.choice == .mute && result.warning != nil)
    }

    @Test("Settings loaded while the room changes from one-to-one to group are refused")
    func categoryChangeDuringLoad() async throws {
        rules.onDefaultRead = { [room] in room.members = 3 }
        await #expect(throws: MatrixServiceError.self) { try await load() }
    }

    @Test("A room the user has left gets no rule changes")
    func leftRoomGetsNoChanges() async throws {
        room.joined = false
        await #expect(throws: MatrixServiceError.self) { try await save(.mute) }
        #expect(rules.writes.all.isEmpty)
    }

    @Test("Unknown encryption is never treated as unencrypted", arguments: [false, true])
    func unknownEncryption(lookupFails: Bool) async throws {
        if lookupFails { room.failsEncryption = true } else { room.encryption = .unknown }
        await #expect(throws: MatrixServiceError.self) { try await load() }
        await #expect(throws: MatrixServiceError.self) { try await save(.mute) }
        #expect(rules.roomReads.all.isEmpty && rules.writes.all.isEmpty)
    }

    @Test("A load error that arrives after switching account is quiet")
    func staleLoadErrorIsQuiet() async throws {
        rules.roomReadGate.arm()
        var current = true
        let pending = Task { try await load { current } }
        #expect(await eventually { rules.roomReadGate.isWaiting })
        current = false
        rules.failsRead = true
        rules.roomReadGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test("An update that completes after switching account publishes nothing and is not repeated")
    func staleSaveIsQuiet() async throws {
        rules.writeGate.arm()
        var current = true
        let pending = Task { try await save(.mute) { current } }
        #expect(await eventually { rules.writeGate.isWaiting })
        current = false
        rules.writeGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(rules.writes.all == ["room:mute"])
    }
}

@MainActor
struct AccountNotificationDefaultsTests {
    private let client = RulesClient()
    private var rules: Rules { client.rules }

    private func save(
        _ category: AccountNotificationCategory, _ mode: AccountNotificationMode,
        isCurrent: @escaping () -> Bool = { true }
    ) async throws -> AccountNotificationDefaultsSaveResult {
        try await AccountNotificationDefaultsService.save(client: client, category: category, mode: mode) {
            guard isCurrent() else { throw CancellationError() }
        }
    }

    // capability: notifications.defaults
    @Test("Loading shows each category's default from the SDK rule for its encryption and size, and changes nothing")
    func loadsEachCategory() async throws {
        let snapshot = try await AccountNotificationDefaultsService.load(client: client, validate: {})
        #expect(
            snapshot.modes == [
                .encryptedOneToOne: .allMessages, .encryptedGroup: .mentionsAndKeywords,
                .unencryptedOneToOne: .mentionsAndKeywords, .unencryptedGroup: .allMessages,
            ])
        #expect(rules.writes.all.isEmpty)
    }

    @Test(
        "Saving a category changes only that category's default rule",
        arguments: [
            (AccountNotificationCategory.encryptedOneToOne, "default:true:true:mentionsAndKeywordsOnly"),
            (.encryptedGroup, "default:true:false:mentionsAndKeywordsOnly"),
            (.unencryptedOneToOne, "default:false:true:mentionsAndKeywordsOnly"),
            (.unencryptedGroup, "default:false:false:mentionsAndKeywordsOnly"),
        ])
    func savesOneCategory(category: AccountNotificationCategory, write: String) async throws {
        let result = try await save(category, .mentionsAndKeywords)
        #expect(rules.writes.all == [write])
        #expect(result.snapshot?[category] == .mentionsAndKeywords && result.warning == nil)
    }

    @Test("A half-applied update still reports failure, and an explicit retry is sent even though the cache matches")
    func halfAppliedUpdateCanBeRetried() async throws {
        rules.failsWrite = true
        rules.appliesBeforeFailure = true
        do {
            _ = try await save(.encryptedGroup, .allMessages)
            Issue.record("a failed update must be reported")
        } catch let failure as AccountNotificationDefaultsSaveFailure {
            #expect(failure.snapshot?[.encryptedGroup] == .allMessages && !failure.warning.isEmpty)
        }
        rules.failsWrite = false
        #expect(try await save(.encryptedGroup, .allMessages).warning == nil)
        #expect(rules.writes.all.count == 2)
    }

    @Test("An accepted update that has not synced yet shows the synced default with a warning")
    func acceptedButLagging() async throws {
        rules.lagsReadback = true
        let result = try await save(.encryptedGroup, .allMessages)
        #expect(result.snapshot?[.encryptedGroup] == .mentionsAndKeywords && result.warning != nil)
    }

    @Test("An accepted update that leaves a default the app cannot show asks for a reload")
    func uninterpretableDefault() async throws {
        rules.unreadableAfterWrite = true
        let result = try await save(.encryptedGroup, .allMessages)
        #expect(result.snapshot == nil && result.warning != nil)
    }

    @Test("Switching account while the settings are fetched sends no update")
    func staleBeforeWrite() async throws {
        client.settingsGate.arm()
        var current = true
        let pending = Task { try await save(.encryptedGroup, .allMessages) { current } }
        #expect(await eventually { client.settingsGate.isWaiting })
        current = false
        client.settingsGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(rules.writes.all.isEmpty)
    }

    @Test(
        "An update that ends after switching account publishes neither result nor readback", arguments: [false, true])
    func staleAfterWrite(fails: Bool) async throws {
        rules.failsWrite = fails
        rules.writeGate.arm()
        var current = true
        let pending = Task { try await save(.encryptedGroup, .allMessages) { current } }
        #expect(await eventually { rules.writeGate.isWaiting })
        current = false
        rules.writeGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(rules.defaultReads.all.isEmpty)
    }

    @Test("A load that finishes after switching account is quiet")
    func staleLoadIsQuiet() async throws {
        rules.defaultReadGate.arm()
        var current = true
        let pending = Task {
            try await AccountNotificationDefaultsService.load(client: client) {
                guard current else { throw CancellationError() }
            }
        }
        #expect(await eventually { rules.defaultReadGate.isWaiting })
        current = false
        rules.defaultReadGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }
}

/// Retry intent outlives the Preferences or room settings pane that started the write.
@MainActor
struct NotificationSettingsRetryStateTests {
    private let roomID = "!room:example.org"
    private let defaults = AccountNotificationDefaultsSnapshot(modes: [.encryptedGroup: .allMessages])

    @Test("Room and account default updates share one write at a time; a second is refused, not queued")
    func oneWriteAtATime() throws {
        let state = NotificationSettingsRetryState()
        _ = try state.begin(.account(category: .encryptedGroup, mode: .allMessages))
        #expect(throws: MatrixServiceError.self) { try state.begin(.room(id: roomID, choice: .mute)) }
        #expect(state.isWriting)
    }

    @Test("A failed default update leaves a retry for a reopened pane even when the cached mode matches")
    func failureLeavesRetry() throws {
        let state = NotificationSettingsRetryState()
        let ticket = try state.begin(.account(category: .encryptedGroup, mode: .allMessages))
        #expect(state.decorate(defaults).pendingRetryModes.isEmpty)
        let revision = state.revision
        state.recordFailure(ticket)
        state.end(ticket)
        #expect(!state.isWriting && state.revision > revision)
        #expect(state.decorate(defaults).pendingRetryModes == [.encryptedGroup: .allMessages])
    }

    @Test("A reopened room pane shows the failed request as the retry, not the cached choice")
    func roomRetryKeepsRequest() throws {
        let state = NotificationSettingsRetryState()
        let ticket = try state.begin(.room(id: roomID, choice: .mute))
        state.recordFailure(ticket)
        state.end(ticket)
        let snapshot = RoomNotificationSnapshot(
            roomID: roomID, isEncrypted: true, isOneToOne: true, choice: .mentionsAndKeywords,
            effectiveChoice: .mentionsAndKeywords, defaultChoice: .allMessages)
        let decorated = state.decorate(snapshot)
        #expect(decorated.choice == .mentionsAndKeywords && decorated.pendingRetryChoice == .mute)
    }

    @Test("An accepted retry clears only its own pending retry")
    func acceptedRetryClearsOnlyItself() throws {
        let state = NotificationSettingsRetryState()
        for target in [
            NotificationSettingsRetryState.Target.room(id: roomID, choice: .mute),
            .account(category: .unencryptedGroup, mode: .allMessages),
            .account(category: .encryptedGroup, mode: .allMessages),
        ] {
            let ticket = try state.begin(target)
            state.recordFailure(ticket)
            state.end(ticket)
        }
        let retry = try state.begin(.account(category: .encryptedGroup, mode: .allMessages))
        state.accepted(retry)
        state.end(retry)
        #expect(state.defaultModes == [.unencryptedGroup: .allMessages])
        #expect(state.roomChoices == [roomID: .mute])
    }

    @Test("After a sign-out, the old session's late failure, success and cleanup do not touch the new session")
    func resetIsolatesSessions() throws {
        let state = NotificationSettingsRetryState()
        let old = try state.begin(.room(id: roomID, choice: .allMessages))
        state.reset()
        let current = try state.begin(.account(category: .encryptedGroup, mode: .mentionsAndKeywords))
        state.recordFailure(current)
        state.recordFailure(old)
        state.accepted(old)
        state.end(old)
        #expect(state.roomChoices.isEmpty && state.defaultModes == [.encryptedGroup: .mentionsAndKeywords])
        #expect(state.isWriting)
        state.end(current)
        state.reset()
        #expect(state.roomChoices.isEmpty && state.defaultModes.isEmpty && !state.isWriting)
    }
}
