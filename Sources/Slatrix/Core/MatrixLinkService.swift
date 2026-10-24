import Foundation
import MatrixRustSDK

struct MatrixRoomJoinRequest: Identifiable, Hashable {
    let id = UUID()
    let accountID: String
    let sessionID: UUID
    let address: String
    let roomID: String
    let via: [String]
    let eventID: String?
    var isSpaceHint: Bool? = nil
}

struct MatrixRoomJoinDestination: Hashable {
    let roomID: String
    let eventID: String?
    let isSpace: Bool?
    var warning: String? = nil
}

enum MatrixLinkDestination: Hashable {
    case profile(userID: String)
    case conversation(roomID: String, eventID: String?)
    case workspace(spaceID: String)
    case join(request: MatrixRoomJoinRequest)
}

struct MatrixLinkResolution: Hashable {
    let accountID: String
    let sessionID: UUID
    let destination: MatrixLinkDestination
}

enum MatrixLinkError: LocalizedError {
    case invalidLink, aliasNotFound, workspaceEvent, banned, joinBusy, detailsSyncing
    var errorDescription: String? {
        switch self {
        case .invalidLink: "Slatrix can’t open this link."
        case .aliasNotFound: "Couldn’t find that conversation."
        case .workspaceEvent: "Slatrix can’t open a message inside a workspace. Use the workspace’s link instead."
        case .banned: "Your account is banned from this conversation."
        case .joinBusy: "A join request for this conversation is already in progress."
        case .detailsSyncing: "This conversation is still loading. Open the link again in a moment."
        }
    }
}

@MainActor
enum MatrixLinkService {
    private struct JoinKey: Hashable {
        let client: ObjectIdentifier
        let roomID: String
    }
    private static var joining = Set<JoinKey>()

    static func isMatrixCandidate(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "matrix" { return true }
        return url.host?.lowercased() == "matrix.to"
    }

    static func parse(_ url: URL) throws -> MatrixEntity? {
        guard isMatrixCandidate(url) else { return nil }
        guard clean(url.absoluteString, limit: 8_192),
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.user == nil, parts.password == nil, parts.port == nil
        else { throw MatrixLinkError.invalidLink }
        if parts.scheme?.lowercased() == "matrix" {
            // The pinned SDK parser accepts URL authorities/fragments; these are not native Matrix navigation forms.
            guard parts.host == nil, parts.fragment == nil else { throw MatrixLinkError.invalidLink }
        } else {
            guard parts.scheme == "https", parts.host == "matrix.to", parts.percentEncodedPath == "/",
                parts.query == nil
            else { throw MatrixLinkError.invalidLink }
            // The pinned Ruma parser indexes empty identifier segments. Reject literal empty
            // segments before crossing FFI; preserve percent-encoded opaque ID characters.
            let identifiers =
                parts.percentEncodedFragment?.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
                .first ?? ""
            guard !identifiers.contains("//") else { throw MatrixLinkError.invalidLink }
        }
        guard let entity = parseMatrixEntityFrom(uri: url.absoluteString) else { throw MatrixLinkError.invalidLink }
        try validateEntity(entity)
        return entity
    }

    static func resolve(
        client: Client, entity: MatrixEntity, accountID: String, sessionID: UUID, validate: () throws -> Void
    ) async throws -> MatrixLinkResolution {
        do {
            try validate()
            try validateEntity(entity)
            let destination: MatrixLinkDestination
            switch entity.id {
            case .user(let id): destination = .profile(userID: id)
            case .room(let id):
                destination = try await roomDestination(
                    client: client, roomID: id, address: id, eventID: nil, via: entity.via, accountID: accountID,
                    sessionID: sessionID, validate: validate)
            case .eventOnRoomId(let id, let event):
                destination = try await roomDestination(
                    client: client, roomID: id, address: id, eventID: event, via: entity.via, accountID: accountID,
                    sessionID: sessionID, validate: validate)
            case .roomAlias(let alias):
                destination = try await aliasDestination(
                    client: client, alias: alias, eventID: nil, via: entity.via, accountID: accountID,
                    sessionID: sessionID, validate: validate)
            case .eventOnRoomAlias(let alias, let event):
                destination = try await aliasDestination(
                    client: client, alias: alias, eventID: event, via: entity.via, accountID: accountID,
                    sessionID: sessionID, validate: validate)
            }
            try validate()
            return MatrixLinkResolution(accountID: accountID, sessionID: sessionID, destination: destination)
        } catch {
            try validate()
            throw error
        }
    }

    private static func aliasDestination(
        client: Client, alias: String, eventID: String?, via: [String], accountID: String, sessionID: UUID,
        validate: () throws -> Void
    ) async throws -> MatrixLinkDestination {
        guard let resolved = try await client.resolveRoomAlias(roomAlias: alias) else {
            try validate()
            throw MatrixLinkError.aliasNotFound
        }
        try validate()
        guard clean(resolved.roomId, limit: 2_048), resolved.roomId.hasPrefix("!") else {
            throw MatrixLinkError.invalidLink
        }
        let servers = try routingServers(via + resolved.servers)
        return try await roomDestination(
            client: client, roomID: resolved.roomId, address: alias, eventID: eventID, via: servers,
            accountID: accountID, sessionID: sessionID, validate: validate)
    }

    private static func roomDestination(
        client: Client, roomID: String, address: String, eventID: String?, via: [String], accountID: String,
        sessionID: UUID, validate: () throws -> Void
    ) async throws -> MatrixLinkDestination {
        try validate()
        let room = try client.getRoom(roomId: roomID)
        if let room, room.membership() == .joined {
            var space: Bool? = room.isSpace() ? true : nil
            if space == nil {
                do {
                    let info = try await room.roomInfo()
                    try validate()
                    // Creators originate in m.room.create, which also carries the room type.
                    if info.id == roomID, !(info.creators?.isEmpty ?? true) { space = info.isSpace }
                } catch { try validate() }
            }
            if space == nil {
                do {
                    let preview = try await client.getRoomPreviewFromRoomId(roomId: roomID, viaServers: via)
                    try validate()
                    let info = preview.info()
                    if info.roomId == roomID { space = info.roomType == .space }
                } catch { try validate() }
            }
            try validate()
            guard room.membership() == .joined else { throw MatrixLinkError.detailsSyncing }
            guard let space else { throw MatrixLinkError.detailsSyncing }
            if space {
                guard eventID == nil else { throw MatrixLinkError.workspaceEvent }
                return .workspace(spaceID: roomID)
            }
            return .conversation(roomID: roomID, eventID: eventID)
        }
        if room?.membership() == .banned { throw MatrixLinkError.banned }
        var hint: Bool? = room?.isSpace() == true ? true : nil
        if hint == nil {
            do {
                let preview = try await client.getRoomPreviewFromRoomId(roomId: roomID, viaServers: via)
                try validate()
                let info = preview.info()
                if info.roomId == roomID { hint = info.roomType == .space }
            } catch {
                // A private room can be joinable even when its preview is unavailable.
                try validate()
            }
        }
        try validate()
        if hint == true, eventID != nil { throw MatrixLinkError.workspaceEvent }
        return .join(
            request: MatrixRoomJoinRequest(
                accountID: accountID, sessionID: sessionID, address: address, roomID: roomID, via: via,
                eventID: eventID, isSpaceHint: hint))
    }

    static func join(client: Client, request: MatrixRoomJoinRequest, validate: () throws -> Void) async throws
        -> MatrixRoomJoinDestination
    {
        try validate()
        guard try client.userId() == request.accountID, clean(request.roomID, limit: 2_048),
            request.roomID.hasPrefix("!")
        else { throw CancellationError() }
        _ = try routingServers(request.via)
        if let eventID = request.eventID, !clean(eventID, limit: 2_048) || !eventID.hasPrefix("$") {
            throw MatrixLinkError.invalidLink
        }
        let key = JoinKey(client: ObjectIdentifier(client), roomID: request.roomID)
        guard joining.insert(key).inserted else { throw MatrixLinkError.joinBusy }
        defer { joining.remove(key) }
        do {
            if let room = try client.getRoom(roomId: request.roomID), room.membership() == .joined {
                return joinedDestination(room: room, request: request)
            }
            // Anchor the reviewed destination, rather than resolving a mutable alias again.
            let room = try await client.joinRoomByIdOrAlias(roomIdOrAlias: request.roomID, serverNames: request.via)
            try validate()
            return joinedDestination(room: room, request: request)
        } catch {
            try validate()
            throw error
        }
    }

    private static func joinedDestination(room: Room, request: MatrixRoomJoinRequest) -> MatrixRoomJoinDestination {
        guard room.id() == request.roomID else {
            return MatrixRoomJoinDestination(
                roomID: request.roomID, eventID: request.eventID, isSpace: nil,
                warning: "You joined, but not the conversation this link points to. Check your sidebar.")
        }
        let isSpace: Bool? = room.isSpace() ? true : request.isSpaceHint
        let warning: String?
        if isSpace == nil {
            warning = "You joined. Open the conversation from your sidebar once it appears."
        } else if isSpace == true, request.eventID != nil {
            warning = "Joined the workspace, but the linked message can’t be opened."
        } else {
            warning = nil
        }
        return MatrixRoomJoinDestination(
            roomID: request.roomID, eventID: request.eventID, isSpace: isSpace, warning: warning)
    }

    private static func validateEntity(_ entity: MatrixEntity) throws {
        let ids: [String]
        switch entity.id {
        case .user(let id), .room(let id), .roomAlias(let id): ids = [id]
        case .eventOnRoomId(let id, let event), .eventOnRoomAlias(let id, let event): ids = [id, event]
        }
        guard ids.allSatisfy({ clean($0, limit: 2_048) }) else { throw MatrixLinkError.invalidLink }
        _ = try routingServers(entity.via)
    }
    private static func routingServers(_ servers: [String]) throws -> [String] {
        guard servers.count <= 32, servers.allSatisfy({ clean($0, limit: 1_024) }) else {
            throw MatrixLinkError.invalidLink
        }
        var seen = Set<String>()
        // The FFI exposes ServerName validation through its typed UserId helper.
        for server in servers {
            guard (try? serverNameFromUserId(userId: "@matrix-link-validation:\(server)")) == server else {
                throw MatrixLinkError.invalidLink
            }
        }
        return servers.filter { seen.insert($0).inserted }
    }
    private static func clean(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
