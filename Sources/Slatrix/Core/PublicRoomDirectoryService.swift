import Foundation
import MatrixRustSDK
import Observation

enum PublicDirectoryJoinRule: String, Hashable {
    case publicRoom, knock, restricted, knockRestricted, invite, unknown
    init(_ rule: PublicRoomJoinRule?) {
        switch rule {
        case .public?: self = .publicRoom
        case .knock?: self = .knock
        case .restricted?: self = .restricted
        case .knockRestricted?: self = .knockRestricted
        case .invite?: self = .invite
        case nil: self = .unknown
        }
    }
}

struct PublicDirectoryRoom: Identifiable, Hashable {
    let id: String
    let name: String?
    let topic: String?
    let alias: String?
    let avatarURL: String?
    let joinRule: PublicDirectoryJoinRule
    let isWorldReadable: Bool
    let joinedMembers: UInt64
    /// Servers that can route a join, from a workspace's hierarchy.
    var via: [String] = []
    /// Listed by a workspace the person belongs to, which is what a restricted channel usually admits.
    var inWorkspace = false
    var displayName: String { name ?? alias ?? id }
    var canJoin: Bool {
        joinRule == .publicRoom || (inWorkspace && [.restricted, .knockRestricted].contains(joinRule))
    }
}

private enum PublicDirectoryMapping {
    static func room(_ source: RoomDescription) -> PublicDirectoryRoom? {
        // The server supplies strings, not a typed RoomId. Parse one opaque path
        // component and require an exact roundtrip; an alias is never identity.
        let id = source.roomId
        guard MatrixID.isValid(id, sigil: "!"),
            let encoded = String(id.dropFirst()).addingPercentEncoding(
                withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))),
            let entity = parseMatrixEntityFrom(uri: "matrix:roomid/" + encoded),
            case .room(let parsed) = entity.id, parsed == id
        else { return nil }
        func text(_ value: String?) -> String? {
            guard let value else { return nil }
            let bounded = String(value.prefix(4_096)).trimmingCharacters(in: .whitespacesAndNewlines)
            return bounded.isEmpty ? nil : bounded
        }
        return PublicDirectoryRoom(
            id: id, name: text(source.name), topic: text(source.topic), alias: text(source.alias),
            avatarURL: text(source.avatarUrl), joinRule: PublicDirectoryJoinRule(source.joinRule),
            isWorldReadable: source.isWorldReadable, joinedMembers: source.joinedMembers)
    }

    /// A workspace's channel, validated like a directory entry. Nested spaces and direct messages are not channels.
    static func channel(_ source: SpaceRoom) -> PublicDirectoryRoom? {
        guard source.roomType == .room, source.isDirect != true, source.isDm != true else { return nil }
        let rule: PublicRoomJoinRule? =
            switch source.joinRule {
            case .public?: .public
            case .knock?: .knock
            case .restricted?: .restricted
            case .knockRestricted?: .knockRestricted
            case .invite?, .private?: .invite
            case .custom?, nil: nil
            }
        var result = room(
            RoomDescription(
                roomId: source.roomId, name: source.rawName ?? source.displayName, topic: source.topic,
                alias: source.canonicalAlias, avatarUrl: source.avatarUrl, joinRule: rule,
                isWorldReadable: source.worldReadable ?? false, joinedMembers: source.numJoinedMembers))
        result?.via = source.via
        result?.inWorkspace = true
        return result
    }

}

private final class PublicDirectoryObserver: RoomDirectorySearchEntriesListener, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RoomDescription] = []
    private var revision = 0
    let callback: @Sendable ([RoomDescription]?, Int) -> Void
    init(_ callback: @escaping @Sendable ([RoomDescription]?, Int) -> Void) { self.callback = callback }
    func onUpdate(roomEntriesUpdate: [RoomDirectorySearchEntryUpdate]) {
        let snapshot: ([RoomDescription]?, Int) = lock.withLock {
            revision += 1
            let valid = values.apply(roomEntriesUpdate.map(\.change))
            return (valid ? values : nil, revision)
        }
        callback(snapshot.0, snapshot.1)
    }
}

@MainActor
@Observable final class PublicRoomDirectoryService {
    private(set) var entries: [PublicDirectoryRoom] = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var scopeID = UUID()
    private var client: Client?
    /// Set while browsing one workspace's channels rather than the server's public directory.
    private(set) var spaceID: String?
    private var spaceChannels: [PublicDirectoryRoom]?
    private var validateSession: (() throws -> Void)?
    private var helper: RoomDirectorySearch?
    private var handle: TaskHandle?
    private var operation: Task<Void, Never>?
    private var resultRevision = 0
    private var searchFinished = false
    private var operationID = UUID()

    func open(client: Client, spaceID: String? = nil, validate: @escaping () throws -> Void) {
        close()
        self.client = client
        self.spaceID = spaceID
        validateSession = validate
    }

    func close() {
        resetQuery()
        client = nil
        spaceID = nil
        spaceChannels = nil
        validateSession = nil
    }

    func search(query: String) async {
        resetQuery()
        guard let client else {
            errorMessage = "Sign in to browse channels."
            return
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.utf8.count <= 2_048, term.rangeOfCharacter(from: .controlCharacters) == nil else {
            errorMessage = "Use a shorter search phrase without control characters."
            return
        }
        let token = scopeID
        do { try check(token) } catch {
            cancelIfCurrent(token)
            return
        }
        if let spaceID {
            await searchWorkspace(client: client, spaceID: spaceID, term: term, token: token)
            return
        }
        let directory = client.roomDirectorySearch()
        helper = directory
        isLoading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.check(token)
                let listener = await directory.results(
                    listener: PublicDirectoryObserver { [weak self] values, revision in
                        Task { @MainActor [weak self] in
                            guard let self, (try? self.check(token)) != nil, revision > self.resultRevision else {
                                return
                            }
                            self.resultRevision = revision
                            guard let values else {
                                self.stopWithError(
                                    "Couldn’t load channels. Search again.",
                                    token: token)
                                return
                            }
                            var rows: [PublicDirectoryRoom] = []
                            var positions: [String: Int] = [:]
                            for room in values.compactMap(PublicDirectoryMapping.room) {
                                if let index = positions[room.id] {
                                    rows[index] = room
                                } else {
                                    positions[room.id] = rows.count
                                    rows.append(room)
                                }
                            }
                            self.entries = rows
                        }
                    })
                do { try self.check(token) } catch {
                    listener.cancel()
                    throw error
                }
                self.handle = listener
                try await directory.search(filter: term.isEmpty ? nil : term, batchSize: 50, viaServerName: nil)
                try self.check(token)
                let lastPage = try await directory.isAtLastPage()
                try self.check(token)
                self.hasMore = !lastPage
                self.searchFinished = true
                self.isLoading = false
            } catch {
                self.finish(error, token: token, keepResults: false)
            }
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Loads the workspace's hierarchy once per opening and filters it locally, so typing never refetches it.
    private func searchWorkspace(client: Client, spaceID: String, term: String, token: UUID) async {
        isLoading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let channels: [PublicDirectoryRoom]
                if let cached = self.spaceChannels {
                    channels = cached
                } else {
                    let list = try await client.spaceService().spaceRoomList(spaceId: spaceID)
                    // shortcut: stops after 50 pages of the hierarchy; page on demand if a workspace outgrows it.
                    for _ in 0..<50 {
                        try self.check(token)
                        if case .idle(endReached: true) = list.paginationState() { break }
                        try await list.paginate()
                    }
                    channels = await list.rooms().compactMap(PublicDirectoryMapping.channel)
                    try self.check(token)
                    self.spaceChannels = channels
                }
                self.entries = channels.filter {
                    term.isEmpty || $0.displayName.localizedCaseInsensitiveContains(term)
                        || ($0.topic?.localizedCaseInsensitiveContains(term) ?? false)
                }
                self.searchFinished = true
                self.isLoading = false
            } catch {
                self.finish(error, token: token, keepResults: false)
            }
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore, searchFinished, let directory = helper else { return }
        let token = scopeID
        let request = UUID()
        do { try check(token) } catch {
            cancelIfCurrent(token)
            return
        }
        operationID = request
        isLoading = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.check(token)
                try await directory.nextPage()
                try self.check(token)
                let lastPage = try await directory.isAtLastPage()
                try self.check(token)
                guard self.operationID == request else { return }
                self.hasMore = !lastPage
                self.isLoading = false
            } catch { self.finish(error, token: token, keepResults: true) }
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        try validateSession?()
        guard client != nil, token == scopeID else { throw CancellationError() }
    }
    private func resetQuery() {
        scopeID = UUID()
        operationID = UUID()
        operation?.cancel()
        operation = nil
        handle?.cancel()
        handle = nil
        helper = nil
        entries = []
        resultRevision = 0
        searchFinished = false
        isLoading = false
        hasMore = false
        errorMessage = nil
    }
    private func cancelIfCurrent(_ token: UUID) { if token == scopeID { resetQuery() } }
    private func stopWithError(_ message: String, token: UUID) {
        guard token == scopeID else { return }
        resetQuery()
        errorMessage = message
    }
    private func finish(_ error: Error, token: UUID, keepResults: Bool) {
        guard token == scopeID else { return }
        do { try validateSession?() } catch {
            resetQuery()
            return
        }
        if error is CancellationError || Task.isCancelled {
            resetQuery()
            return
        }
        if !keepResults {
            stopWithError(MatrixService.safeError(error), token: token)
        } else {
            isLoading = false
            errorMessage = MatrixService.safeError(error)
        }
    }
}
