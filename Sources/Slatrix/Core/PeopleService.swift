import Foundation
import MatrixRustSDK
import Observation

struct PersonProfile: Identifiable, Hashable {
    var id: String
    var name: String
    var avatarURL: String? = nil
    var status: String? = nil
    var profileAvailable = true
}

enum PeopleMapping {
    static func validatedID(_ input: String) throws -> String {
        let id = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MatrixID.isValid(id, sigil: "@"), (try? serverNameFromUserId(userId: id)) != nil
        else {
            throw MatrixServiceError.request("Enter a complete Matrix ID, such as @name:example.org.")
        }
        return id
    }

    static func profile(_ value: UserProfile, statusSupported: Bool) -> PersonProfile {
        let name = value.displayName.flatMap { $0.isEmpty ? nil : String($0.prefix(512)) } ?? value.userId
        let status =
            statusSupported
            ? value.status.map {
                [String($0.emoji.prefix(32)), String($0.text.prefix(512))].filter { !$0.isEmpty }.joined(separator: " ")
            } : nil
        return PersonProfile(
            id: value.userId, name: name, avatarURL: value.avatarUrl, status: status?.isEmpty == false ? status : nil)
    }

    static func exactDirectParticipants(_ members: [RoomMember], ownUserID: String, targetUserID: String) -> Bool {
        let active = members.filter { $0.membership == .join || $0.membership == .invite }
        return Set(active.map(\.userId)) == Set([ownUserID, targetUserID])
            && active.contains { $0.userId == ownUserID && $0.membership == .join }
    }
}

@MainActor
@Observable final class PeopleService {
    private(set) var results: [PersonProfile] = []
    private(set) var searchState = "idle"
    private(set) var searchErrorMessage: String?
    private(set) var limited = false
    private(set) var profile: PersonProfile?
    private(set) var profileState = "idle"
    private(set) var profileErrorMessage: String?
    private(set) var statusSupported = false
    private var client: Client?
    private var generation = UUID()
    private var searchGeneration = UUID()
    private var profileGeneration = UUID()
    private var searchTask: Task<Void, Never>?
    private var profileTask: Task<Void, Never>?
    private var knownStatusSupport: Bool?
    private var directTasks: [String: Task<String, Error>] = [:]
    private var pendingDirectRooms: [String: String] = [:]

    func attach(_ client: Client?) {
        generation = UUID()
        cancelSearch()
        dismissProfile()
        for item in directTasks.values { item.cancel() }
        directTasks = [:]
        pendingDirectRooms = [:]
        self.client = client
        knownStatusSupport = nil
        statusSupported = false
    }

    func cancelSearch() {
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        results = []
        searchState = "idle"
        searchErrorMessage = nil
        limited = false
    }

    func search(_ query: String) async {
        cancelSearch()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard query.utf8.count <= 1024 else {
            searchState = "error"
            searchErrorMessage = "Use a shorter name or Matrix ID."
            return
        }
        guard let client else {
            searchState = "error"
            searchErrorMessage = "Sign in to search for people."
            return
        }
        let session = generation
        let request = searchGeneration
        searchState = "loading"
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.generation == session, self.searchGeneration == request else { return }
                var values: [UserProfile] = []
                var directoryFailure: Error?
                var isLimited = false
                var exactFallback: PersonProfile?
                do {
                    let directory = try await client.searchUsers(searchTerm: query, limit: 50)
                    values = directory.results
                    isLimited = directory.limited
                } catch { directoryFailure = error }
                guard self.generation == session, self.searchGeneration == request, !Task.isCancelled else { return }
                if let exactID = try? PeopleMapping.validatedID(query),
                    !values.contains(where: { $0.userId == exactID })
                {
                    do {
                        let exact = try await client.getProfile(userId: exactID)
                        if exact.userId == exactID { values.insert(exact, at: 0) }
                    } catch {
                        exactFallback = PersonProfile(id: exactID, name: exactID, profileAvailable: false)
                    }
                }
                guard self.generation == session, self.searchGeneration == request, !Task.isCancelled else { return }
                if values.isEmpty, exactFallback == nil, let directoryFailure { throw directoryFailure }
                var seen = Set<String>()
                self.results = values.filter {
                    (try? PeopleMapping.validatedID($0.userId)) != nil && seen.insert($0.userId).inserted
                }
                .map { PeopleMapping.profile($0, statusSupported: self.statusSupported) }
                if let exactFallback {
                    self.results.insert(exactFallback, at: 0)
                    self.searchErrorMessage =
                        "No public profile for this ID."
                }
                self.limited = isLimited || directoryFailure != nil || exactFallback != nil
                self.searchState = "ready"
            } catch {
                guard let self, self.generation == session, self.searchGeneration == request, !Task.isCancelled else {
                    return
                }
                self.results = []
                self.searchState = "error"
                self.searchErrorMessage = MatrixService.safeError(error)
            }
        }
        searchTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func dismissProfile() {
        profileGeneration = UUID()
        profileTask?.cancel()
        profileTask = nil
        profile = nil
        profileState = "idle"
        profileErrorMessage = nil
    }

    func loadProfile(userID: String, fallback: ChatUser? = nil) async {
        dismissProfile()
        let id: String
        do { id = try PeopleMapping.validatedID(userID) } catch {
            profileState = "error"
            profileErrorMessage = MatrixService.safeError(error)
            return
        }
        guard let client else {
            profileState = "error"
            profileErrorMessage = "Sign in to view this profile."
            return
        }
        let session = generation
        let request = profileGeneration
        let fallback = fallback?.id == id ? fallback : nil
        profile = PersonProfile(
            id: id, name: fallback?.name ?? id, avatarURL: fallback?.avatarURL, profileAvailable: false)
        profileState = "loading"
        let task = Task { [weak self] in
            guard let self, self.generation == session, self.profileGeneration == request, !Task.isCancelled else {
                return
            }
            do {
                let value = try await client.getProfile(userId: id)
                guard self.generation == session, self.profileGeneration == request, !Task.isCancelled else { return }
                guard value.userId == id else {
                    throw MatrixServiceError.request("Couldn’t load this profile. Try again.")
                }
                var support = self.knownStatusSupport
                if support == nil {
                    // Optional status discovery must not prevent reading the core name/avatar profile.
                    support = try? await client.isUserStatusSupported()
                }
                guard self.generation == session, self.profileGeneration == request, !Task.isCancelled else { return }
                self.knownStatusSupport = support
                self.statusSupported = self.knownStatusSupport == true
                self.profile = PeopleMapping.profile(value, statusSupported: self.statusSupported)
                self.profileState = "ready"
            } catch {
                guard self.generation == session, self.profileGeneration == request, !Task.isCancelled else { return }
                self.profileState = "error"
                self.profileErrorMessage = MatrixService.safeError(error)
            }
        }
        profileTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func directRoom(userID: String) async throws -> String {
        let id = try PeopleMapping.validatedID(userID)
        guard let client else { throw MatrixServiceError.signedOut }
        let ownID = try client.userId()
        guard id != ownID else { throw MatrixServiceError.request("You are already signed in as this person.") }
        let session = generation
        if let existing = directTasks[id] {
            let roomID = try await existing.value
            try checkSession(session)
            return roomID
        }
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            try self.checkSession(session)
            if let pending = self.pendingDirectRooms[id] {
                if try client.getRoom(roomId: pending) == nil { return pending }
                self.pendingDirectRooms[id] = nil
            }
            var plaintext: Room?
            for room in try client.getDmRooms(userId: id).sorted(by: { $0.id() < $1.id() })
            where room.membership() == .joined {
                try self.checkSession(session)
                let direct = await room.isDirect()
                try self.checkSession(session)
                guard direct else { continue }
                guard try await self.exactMembers(room, ownID: ownID, targetID: id, session: session) else { continue }
                let encrypted = await room.isEncrypted()
                try self.checkSession(session)
                guard room.membership() == .joined else { continue }
                if encrypted { return room.id() }
                if plaintext == nil { plaintext = room }
            }
            if let plaintext, plaintext.membership() == .joined,
                try await self.exactMembers(plaintext, ownID: ownID, targetID: id, session: session)
            {
                try self.checkSession(session)
                try await plaintext.enableEncryption()
                try self.checkSession(session)
                guard plaintext.membership() == .joined else { throw MatrixServiceError.noRoom }
                return plaintext.id()
            }
            try self.checkSession(session)
            let roomID = try await client.createRoom(
                request: CreateRoomParameters(
                    name: nil, isEncrypted: true, isDirect: true, visibility: .private, preset: .trustedPrivateChat,
                    invite: [id]))
            try self.checkSession(session)
            self.pendingDirectRooms[id] = roomID
            return roomID
        }
        directTasks[id] = task
        defer { if generation == session { directTasks[id] = nil } }
        let roomID = try await task.value
        try checkSession(session)
        return roomID
    }

    private func exactMembers(_ room: Room, ownID: String, targetID: String, session: UUID) async throws -> Bool {
        let iterator = try await room.members()
        try checkSession(session)
        // nextChunk is a synchronous FFI call; keep it off the main thread.
        let members = await Task.detached(priority: .userInitiated) {
            var members: [RoomMember] = []
            while let chunk = iterator.nextChunk(chunkSize: 100), !chunk.isEmpty { members += chunk }
            return members
        }.value
        try checkSession(session)
        return PeopleMapping.exactDirectParticipants(members, ownUserID: ownID, targetUserID: targetID)
    }

    private func checkSession(_ token: UUID) throws {
        guard generation == token, client != nil, !Task.isCancelled else { throw CancellationError() }
    }
}
