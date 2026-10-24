import Foundation
import MatrixRustSDK

enum RoomDetailsField: String, Hashable { case name, topic }

struct RoomDetailsSnapshot: Hashable {
    let roomID: String
    var name: String
    var topic: String
    let isSpace: Bool
    let canEditName: Bool
    let canEditTopic: Bool
}

struct RoomDetailsSaveResult {
    let snapshot: RoomDetailsSnapshot
    let savedFields: Set<RoomDetailsField>
}

struct RoomDetailsPartialFailure: LocalizedError {
    let result: RoomDetailsSaveResult
    let failedField: RoomDetailsField
    let warning: String
    var errorDescription: String? { warning }
}

@MainActor
enum RoomDetailsService {
    static func load(room: Room, validate: () throws -> Void) async throws -> RoomDetailsSnapshot {
        do {
            try validateJoined(room, validate)
            let info = try await room.roomInfo()
            try validateJoined(room, validate)
            let powers = try await room.getPowerLevels()
            try validateJoined(room, validate)
            return RoomDetailsSnapshot(
                roomID: room.id(), name: info.rawName ?? "", topic: info.topic ?? "", isSpace: info.isSpace,
                canEditName: powers.canOwnUserSendState(stateEvent: .roomName),
                canEditTopic: powers.canOwnUserSendState(stateEvent: .roomTopic))
        } catch {
            try validateJoined(room, validate)
            throw error
        }
    }

    static func save(room: Room, name: String?, topic: String?, validate: () throws -> Void) async throws
        -> RoomDetailsSaveResult
    {
        var latest = try await load(room: room, validate: validate)
        var pending: [(RoomDetailsField, String)] = []
        if let name, name != latest.name {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MatrixServiceError.emptyName
            }
            pending.append((.name, name))
        }
        if let topic, topic != latest.topic { pending.append((.topic, topic)) }
        // Reject known permission failures before making either change.
        for (field, _) in pending { try requirePermission(field, in: latest) }
        var accepted: [RoomDetailsField: String] = [:]
        for (field, value) in pending {
            do {
                latest = try await load(room: room, validate: validate)
                try requirePermission(field, in: latest)
                switch field {
                case .name: if latest.name != value { try await room.setName(name: value) }
                case .topic: if latest.topic != value { try await room.setTopic(topic: value) }
                }
                try validateJoined(room, validate)
                accepted[field] = value
            } catch {
                try validateJoined(room, validate)
                guard !accepted.isEmpty else { throw error }
                let saved = result(latest, accepted)
                let savedName = accepted[.name] != nil ? "The name was saved." : "The description was saved."
                let failedName = field == .name ? "name" : "description"
                throw RoomDetailsPartialFailure(
                    result: saved, failedField: field,
                    warning: "\(savedName) The \(failedName) could not be saved. \(MatrixService.safeError(error))")
            }
        }
        // A successful setter is authoritative even before its sync echo updates RoomInfo.
        return result(latest, accepted)
    }

    private static func result(_ snapshot: RoomDetailsSnapshot, _ accepted: [RoomDetailsField: String])
        -> RoomDetailsSaveResult
    {
        var current = snapshot
        if let name = accepted[.name] { current.name = name }
        if let topic = accepted[.topic] { current.topic = topic }
        return RoomDetailsSaveResult(snapshot: current, savedFields: Set(accepted.keys))
    }
    private static func requirePermission(_ field: RoomDetailsField, in snapshot: RoomDetailsSnapshot) throws {
        guard field == .name ? snapshot.canEditName : snapshot.canEditTopic else {
            throw MatrixServiceError.request(
                "You do not have permission to change this conversation’s \(field == .name ? "name" : "description").")
        }
    }
    private static func validateJoined(_ room: Room, _ validate: () throws -> Void) throws {
        try validate()
        guard room.membership() == .joined else {
            throw MatrixServiceError.request("Join this conversation before editing its details.")
        }
    }
}
