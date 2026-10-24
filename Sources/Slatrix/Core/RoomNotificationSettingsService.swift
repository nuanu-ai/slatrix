import Foundation
import MatrixRustSDK

enum RoomNotificationChoice: String, CaseIterable, Identifiable {
    case accountDefault, allMessages, mentionsAndKeywords, mute
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accountDefault: "Use account default"
        case .allMessages: "All messages"
        case .mentionsAndKeywords: "Mentions and keywords"
        case .mute: "Nothing · mute conversation"
        }
    }
    fileprivate var mode: RoomNotificationMode? {
        switch self {
        case .accountDefault: nil
        case .allMessages: .allMessages
        case .mentionsAndKeywords: .mentionsAndKeywordsOnly
        case .mute: .mute
        }
    }
    fileprivate init(_ mode: RoomNotificationMode) {
        switch mode {
        case .allMessages: self = .allMessages
        case .mentionsAndKeywordsOnly: self = .mentionsAndKeywords
        case .mute: self = .mute
        }
    }
}

struct RoomNotificationSnapshot: Hashable {
    let roomID: String
    let isEncrypted: Bool
    let isOneToOne: Bool
    let choice: RoomNotificationChoice
    let effectiveChoice: RoomNotificationChoice
    let defaultChoice: RoomNotificationChoice
    var pendingRetryChoice: RoomNotificationChoice? = nil
}

struct RoomNotificationSaveResult {
    let requestedChoice: RoomNotificationChoice
    let snapshot: RoomNotificationSnapshot?
    let warning: String?
}

struct RoomNotificationSaveFailure: LocalizedError {
    let snapshot: RoomNotificationSnapshot?
    let warning: String
    var errorDescription: String? { warning }
}

@MainActor enum RoomNotificationSettingsService {
    private struct Context: Equatable {
        let roomID: String
        let encrypted: Bool
        let oneToOne: Bool
    }

    static func load(client: Client, room: Room, validate: () throws -> Void) async throws -> RoomNotificationSnapshot {
        do {
            try check(room, validate)
            let settings = await client.getNotificationSettings()
            try check(room, validate)
            return try await read(settings, room, validate)
        } catch {
            try check(room, validate)
            throw error
        }
    }

    static func save(client: Client, room: Room, choice: RoomNotificationChoice, validate: () throws -> Void)
        async throws -> RoomNotificationSaveResult
    {
        try check(room, validate)
        let settings = await client.getNotificationSettings()
        try check(room, validate)
        _ = try await context(room, validate)
        do {
            if let mode = choice.mode {
                try await settings.setRoomNotificationMode(roomId: room.id(), mode: mode)
            } else {
                try await settings.restoreDefaultRoomNotificationMode(roomId: room.id())
            }
            try check(room, validate)
        } catch {
            try check(room, validate)
            let snapshot = try? await read(settings, room, validate)
            try check(room, validate)
            throw RoomNotificationSaveFailure(
                snapshot: snapshot,
                warning:
                    "Couldn’t finish saving; part of it may have changed. Reload to check. "
                    + MatrixService.safeError(error))
        }
        do {
            let snapshot = try await read(settings, room, validate)
            let warning =
                snapshot.choice == choice
                ? nil
                : "Couldn’t confirm the change. Reload and try again."
            return RoomNotificationSaveResult(requestedChoice: choice, snapshot: snapshot, warning: warning)
        } catch {
            try check(room, validate)
            return RoomNotificationSaveResult(
                requestedChoice: choice, snapshot: nil,
                warning:
                    "Saved, but couldn’t read the result. Reload to check. "
                    + MatrixService.safeError(error))
        }
    }

    private static func read(_ settings: NotificationSettings, _ room: Room, _ validate: () throws -> Void) async throws
        -> RoomNotificationSnapshot
    {
        do {
            let before = try await context(room, validate)
            try check(room, validate)
            let value = try await settings.getRoomNotificationSettings(
                roomId: before.roomID, isEncrypted: before.encrypted, isOneToOne: before.oneToOne)
            try check(room, validate)
            let fallback = await settings.getDefaultRoomNotificationMode(
                isEncrypted: before.encrypted, isOneToOne: before.oneToOne)
            try check(room, validate)
            let after = try await context(room, validate)
            guard before == after else {
                throw MatrixServiceError.request(
                    "This conversation changed while loading notification settings. Reload and try again.")
            }
            return RoomNotificationSnapshot(
                roomID: before.roomID, isEncrypted: before.encrypted, isOneToOne: before.oneToOne,
                choice: value.isDefault ? .accountDefault : RoomNotificationChoice(value.mode),
                effectiveChoice: RoomNotificationChoice(value.mode), defaultChoice: RoomNotificationChoice(fallback))
        } catch {
            try check(room, validate)
            throw error
        }
    }
    private static func context(_ room: Room, _ validate: () throws -> Void) async throws -> Context {
        try check(room, validate)
        let state = try await room.latestEncryptionState()
        try check(room, validate)
        let encrypted: Bool
        switch state {
        case .encrypted: encrypted = true
        case .notEncrypted: encrypted = false
        case .unknown:
            throw MatrixServiceError.request("This conversation is still loading. Reload and try again.")
        }
        return Context(roomID: room.id(), encrypted: encrypted, oneToOne: room.activeMembersCount() == 2)
    }
    private static func check(_ room: Room, _ validate: () throws -> Void) throws {
        try Task.checkCancellation()
        try validate()
        guard room.membership() == .joined else {
            throw MatrixServiceError.request("Join this conversation before changing its notification settings.")
        }
    }
}
