import Foundation
import MatrixRustSDK

enum AccountNotificationMode: String, CaseIterable, Identifiable {
    case allMessages, mentionsAndKeywords
    var id: String { rawValue }
    var title: String { self == .allMessages ? "All messages" : "Mentions and keywords" }
    fileprivate var sdkMode: RoomNotificationMode { self == .allMessages ? .allMessages : .mentionsAndKeywordsOnly }
    fileprivate init(_ mode: RoomNotificationMode) throws {
        switch mode {
        case .allMessages: self = .allMessages
        case .mentionsAndKeywordsOnly: self = .mentionsAndKeywords
        case .mute:
            throw MatrixServiceError.request(
                "Couldn’t read your notification settings. Reload them.")
        }
    }
}

enum AccountNotificationCategory: String, CaseIterable, Identifiable {
    case encryptedOneToOne, encryptedGroup, unencryptedOneToOne, unencryptedGroup
    var id: String { rawValue }
    var isEncrypted: Bool { self == .encryptedOneToOne || self == .encryptedGroup }
    var isOneToOne: Bool { self == .encryptedOneToOne || self == .unencryptedOneToOne }
    var title: String {
        switch self {
        case .encryptedOneToOne: "Encrypted one-to-one conversations"
        case .encryptedGroup: "Encrypted group conversations"
        case .unencryptedOneToOne: "Unencrypted one-to-one conversations"
        case .unencryptedGroup: "Unencrypted group conversations"
        }
    }
}

struct AccountNotificationDefaultsSnapshot: Hashable {
    let modes: [AccountNotificationCategory: AccountNotificationMode]
    var pendingRetryModes: [AccountNotificationCategory: AccountNotificationMode] = [:]
    subscript(_ category: AccountNotificationCategory) -> AccountNotificationMode? { modes[category] }
}

struct AccountNotificationDefaultsSaveResult {
    let requestedCategory: AccountNotificationCategory
    let requestedMode: AccountNotificationMode
    let snapshot: AccountNotificationDefaultsSnapshot?
    let warning: String?
}

struct AccountNotificationDefaultsSaveFailure: LocalizedError {
    let snapshot: AccountNotificationDefaultsSnapshot?
    let warning: String
    var errorDescription: String? { warning }
}

@MainActor
enum AccountNotificationDefaultsService {
    static func load(client: Client, validate: () throws -> Void) async throws -> AccountNotificationDefaultsSnapshot {
        do {
            try check(validate)
            let settings = await client.getNotificationSettings()
            try check(validate)
            return try await read(settings, validate)
        } catch {
            try check(validate)
            throw error
        }
    }

    static func save(
        client: Client, category: AccountNotificationCategory, mode: AccountNotificationMode,
        validate: () throws -> Void
    ) async throws -> AccountNotificationDefaultsSaveResult {
        try check(validate)
        let settings = await client.getNotificationSettings()
        try check(validate)
        do {
            // The official setter updates message then poll-start rules. Poll rules
            // are keyed only by one-to-one/group, shared across encryption types.
            // Mute is deliberately absent: SDK maps it to mentions, not global mute.
            try await settings.setDefaultRoomNotificationMode(
                isEncrypted: category.isEncrypted, isOneToOne: category.isOneToOne, mode: mode.sdkMode)
            try check(validate)
        } catch {
            try check(validate)
            let snapshot = try? await read(settings, validate)
            try check(validate)
            // A matching cached mode doesn't prove the later poll rule update landed.
            throw AccountNotificationDefaultsSaveFailure(
                snapshot: snapshot,
                warning:
                    "Couldn’t confirm the change. Reload and try again. "
                    + MatrixService.safeError(error))
        }
        do {
            let snapshot = try await read(settings, validate)
            let warning =
                snapshot[category] == mode
                ? nil
                : "Couldn’t confirm the change. Reload and try again."
            return AccountNotificationDefaultsSaveResult(
                requestedCategory: category, requestedMode: mode, snapshot: snapshot, warning: warning)
        } catch {
            try check(validate)
            return AccountNotificationDefaultsSaveResult(
                requestedCategory: category, requestedMode: mode, snapshot: nil,
                warning:
                    "Saved, but couldn’t read the result. Reload to check. "
                    + MatrixService.safeError(error))
        }
    }

    private static func read(_ settings: NotificationSettings, _ validate: () throws -> Void) async throws
        -> AccountNotificationDefaultsSnapshot
    {
        var modes: [AccountNotificationCategory: AccountNotificationMode] = [:]
        for category in AccountNotificationCategory.allCases {
            try check(validate)
            // Reads the SDK cache, not the server.
            let mode = await settings.getDefaultRoomNotificationMode(
                isEncrypted: category.isEncrypted, isOneToOne: category.isOneToOne)
            try check(validate)
            modes[category] = try AccountNotificationMode(mode)
        }
        return AccountNotificationDefaultsSnapshot(modes: modes)
    }

    private static func check(_ validate: () throws -> Void) throws {
        try Task.checkCancellation()
        try validate()
    }
}
