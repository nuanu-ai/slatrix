import Foundation
import MatrixRustSDK

struct RoomCreationPartialFailure: LocalizedError {
    let roomID: String
    let warning =
        "Created, but couldn’t add it to the workspace."
    var errorDescription: String? { warning }
}

@MainActor
enum RoomManagementActions {
    static func createRoom(
        client: Client, name: String, topic: String, workspace: Room?, validate: () throws -> Void,
        link: (String) async throws -> Void
    ) async throws -> String {
        do {
            try validate()
            if let workspace {
                guard workspace.isSpace(), workspace.membership() == .joined else {
                    throw MatrixServiceError.request("Join the workspace before creating a channel in it.")
                }
                let powers = try await workspace.getPowerLevels()
                try validate()
                guard workspace.membership() == .joined, powers.canOwnUserSendState(stateEvent: .spaceChild) else {
                    throw MatrixServiceError.request("You do not have permission to manage channels in this workspace.")
                }
            }
            let id = try await client.createRoom(
                request: CreateRoomParameters(
                    name: name, topic: topic, isEncrypted: true, visibility: .private, preset: .privateChat))
            try validate()
            if workspace != nil {
                do {
                    try await link(id)
                    try validate()
                } catch {
                    try validate()
                    throw RoomCreationPartialFailure(roomID: id)
                }
            }
            return id
        } catch {
            try validate()
            throw error
        }
    }

    static func joinRoom(client: Client, address: String, validate: () throws -> Void) async throws -> String {
        do {
            try validate()
            let room = try await client.joinRoomByIdOrAlias(roomIdOrAlias: address, serverNames: [])
            try validate()
            return room.id()
        } catch {
            try validate()
            throw error
        }
    }

    static func leaveRoom(room: Room, validate: () throws -> Void) async throws {
        do {
            try validate()
            try await room.leave()
            try validate()
        } catch {
            try validate()
            throw error
        }
    }
}
