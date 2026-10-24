import Combine
import Foundation

/// Orders UI snapshots and encrypted commits across the SDK send boundary.
@MainActor final class AttachmentDraftController: ObservableObject {
    @Published private(set) var queues: [AttachmentDraftAddress: [URL]] = [:]
    @Published private(set) var files: [AttachmentDraftAddress: [AttachmentDraftFile]] = [:]
    @Published private(set) var ready = false
    @Published private(set) var errorMessage: String?

    @MainActor private final class Session {
        let accountID: String?
        let access: AttachmentDraftAccess?
        var queues: [AttachmentDraftAddress: [URL]] = [:]
        var files: [AttachmentDraftAddress: [AttachmentDraftFile]] = [:]
        var revisions: [AttachmentDraftAddress: UInt64] = [:]
        var changes: [AttachmentDraftAddress: UInt64] = [:]
        var reviewed = Set<String>()
        var delivered: [URL: AttachmentDraftAddress] = [:]
        // Keep confirmed URLs after cleanup, so an older queued snapshot cannot resurrect them.
        var confirmed = Set<URL>()
        var inFlight = Set<URL>()
        var tail: Task<Void, Error>?
        var transition: Task<Void, Never>?
        var errorMessage: String?
        var closed = false
        init(accountID: String?, access: AttachmentDraftAccess?) {
            self.accountID = accountID
            self.access = access
        }
    }
    private let store: AttachmentDraftStore
    private var current: Session?
    private var suspended: [String: Session] = [:]
    private var generation = UUID()

    init(store: AttachmentDraftStore = .shared) { self.store = store }

    func open(accountID: String?) async {
        let request = UUID()
        generation = request
        await detachCurrent()
        guard generation == request else { return }
        if let accountID, let retained = suspended[accountID] {
            await retained.transition?.value
            guard generation == request else { return }
            if suspended[accountID] === retained, !retained.closed {
                suspended[accountID] = nil
                current = retained
                ready = true
                publish(retained)
                do { try await persist(retained) } catch {
                    retained.errorMessage = error.localizedDescription
                    publish(retained)
                }
                return
            }
        }
        guard let accountID else {
            current = Session(accountID: nil, access: nil)
            ready = true
            return
        }
        do {
            let opened = try await store.open(accountID: accountID)
            guard generation == request else {
                await store.close(access: opened)
                return
            }
            do {
                let restored = try await store.restore(access: opened)
                guard generation == request else {
                    await store.close(access: opened)
                    return
                }
                let session = Session(accountID: accountID, access: opened)
                for queue in restored {
                    session.queues[queue.address] = queue.files.compactMap(\.url)
                    session.files[queue.address] = queue.files
                    session.revisions[queue.address] = queue.revision
                }
                session.errorMessage = opened.warningMessage
                current = session
                ready = true
                publish(session)
            } catch {
                await store.close(access: opened)
                throw error
            }
        } catch {
            if generation == request {
                ready = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Immediately hides account data; failed commits retain their private staging and lease.
    func deactivate() async {
        generation = UUID()
        await detachCurrent()
    }

    func set(_ urls: [URL], at address: AttachmentDraftAddress) {
        guard ready, let session = current, !session.closed else { return }
        let pending = urls.filter { !session.confirmed.contains($0) }
        guard session.queues[address, default: []] != pending else { return }
        session.queues[address] = pending
        session.files[address]?.removeAll { file in file.url.map { !pending.contains($0) } ?? false }
        session.changes[address, default: 0] &+= 1
        let change = session.changes[address]
        publish(session)
        guard let access = session.access else { return }
        enqueue(session) {
            try await self.finishDelivered(session)
            let filtered = pending.filter { !session.confirmed.contains($0) }
            let queue = try await self.store.save(
                urls: filtered, address: address, access: access, revision: self.nextRevision(address, session))
            if session.changes[address] == change { self.adoptFiles(queue, session) }
        }
    }

    func discard(_ urls: [URL]) {
        let previous = current?.tail
        Task { @MainActor in
            _ = await previous?.result
            let retained = Set(
                (self.current.map { Array($0.queues.values.joined()) } ?? [])
                    + self.suspended.values.flatMap { $0.queues.values.flatMap { $0 } })
            let unused = urls.filter { !retained.contains($0) }
            await Task.detached { ComposerAttachmentImporter.discard(unused) }.value
        }
    }
    func needsReview(_ address: AttachmentDraftAddress) -> Bool {
        guard let session = current else { return false }
        return session.files[address, default: []].contains {
            $0.phase == .interrupted && !session.reviewed.contains($0.id)
        }
    }
    func allowResend(_ address: AttachmentDraftAddress) {
        guard let session = current else { return }
        objectWillChange.send()
        session.reviewed.formUnion(session.files[address, default: []].filter { $0.phase == .interrupted }.map(\.id))
    }
    func canSend(_ address: AttachmentDraftAddress) -> Bool {
        ready && !needsReview(address) && !files[address, default: []].contains { $0.url == nil }
    }
    func removeUnavailable(_ file: AttachmentDraftFile, at address: AttachmentDraftAddress) {
        guard ready, let session = current, let access = session.access else { return }
        enqueue(session) {
            try await self.finishDelivered(session)
            try await self.store.remove(
                fileID: file.id, address: address, access: access, revision: self.nextRevision(address, session))
            session.files[address]?.removeAll { $0.id == file.id }
        }
    }

    func prepareSend(_ url: URL, at address: AttachmentDraftAddress) async throws {
        guard canSend(address), let session = current, let access = session.access, !session.inFlight.contains(url)
        else { throw AttachmentDraftError.unavailable }
        let request = generation
        try await flush()
        guard generation == request, current === session else { throw AttachmentDraftError.staleAccess }
        guard canSend(address), session.queues[address, default: []].contains(url), !session.inFlight.contains(url)
        else { throw AttachmentDraftError.unavailable }
        let operation = enqueue(session) {
            guard self.generation == request, self.current === session else { throw AttachmentDraftError.staleAccess }
            guard self.canSend(address), session.queues[address, default: []].contains(url),
                !session.inFlight.contains(url)
            else { throw AttachmentDraftError.unavailable }
            try await self.store.markSending(
                url: url, address: address, access: access, revision: self.nextRevision(address, session))
            session.inFlight.insert(url)
        }
        try await operation.value
        guard generation == request, current === session else { throw AttachmentDraftError.staleAccess }
    }

    func didFail(_ url: URL, at address: AttachmentDraftAddress) async {
        guard let session = current, session.inFlight.remove(url) != nil else { return }
        markInterrupted([url], session)
        publish(session)
    }

    /// SDK success stays success even when removal of the durable draft needs a retry.
    func didSend(_ url: URL, at address: AttachmentDraftAddress) async {
        guard let session = current, session.access != nil else { return }
        session.delivered[url] = address
        session.confirmed.insert(url)
        session.inFlight.remove(url)
        session.queues[address]?.removeAll { $0 == url }
        session.files[address]?.removeAll { $0.url == url }
        session.changes[address, default: 0] &+= 1
        publish(session)
        let operation = enqueue(session) { try await self.finishDelivered(session) }
        _ = await operation.result
        if session.delivered[url] != nil {
            session.errorMessage =
                "Sent, but couldn’t clear the saved draft. Retry before quitting."
            publish(session)
        }
    }

    func flush() async throws {
        let request = generation
        for (account, session) in Array(suspended) {
            await session.transition?.value
            guard generation == request else { throw AttachmentDraftError.staleAccess }
            guard suspended[account] === session, !session.closed else { continue }
            do { try await persist(session) } catch {
                if generation == request {
                    errorMessage =
                        "Couldn’t save attachments from your last sign-in. Retry before quitting."
                }
                throw error
            }
            guard generation == request else { throw AttachmentDraftError.staleAccess }
            await dispose(session)
            if suspended[account] === session { suspended[account] = nil }
        }
        guard generation == request else { throw AttachmentDraftError.staleAccess }
        guard let session = current else { return }
        try await persist(session)
        guard generation == request, current === session else { throw AttachmentDraftError.staleAccess }
    }

    /// Call after flush on normal quit; replacement accounts use the same lossless suspension path.
    func close() async { await deactivate() }

    private func detachCurrent() async {
        let session = current
        current = nil
        ready = false
        queues = [:]
        files = [:]
        errorMessage = nil
        guard let session else { return }
        if let account = session.accountID { suspended[account] = session }
        let transition = Task { @MainActor in
            do {
                try await self.persist(session)
                await self.dispose(session)
                if let account = session.accountID, self.suspended[account] === session {
                    self.suspended[account] = nil
                }
            } catch {
                // Detached SDK callbacks are ignored by Root; a retained send needs explicit review.
                self.markInterrupted(session.inFlight, session)
                session.inFlight = []
                session.errorMessage = error.localizedDescription
            }
            session.transition = nil
        }
        session.transition = transition
        await transition.value
    }

    private func dispose(_ session: Session) async {
        _ = await session.tail?.result
        guard !session.closed else { return }
        session.closed = true
        // Detached SDK work may still finish; durable Sending restores as interrupted, requiring review.
        let staged = Array(session.queues.values.joined())
        if let access = session.access { await store.close(access: access) }
        await Task.detached { ComposerAttachmentImporter.discard(staged) }.value
    }

    private func persist(_ session: Session) async throws {
        guard let access = session.access else { return }
        let snapshot = session.queues
        let versions = session.changes
        let operation = enqueue(session) {
            try await self.finishDelivered(session)
            for (address, urls) in snapshot {
                let pending = urls.filter { !session.confirmed.contains($0) }
                let queue = try await self.store.save(
                    urls: pending, address: address, access: access, revision: self.nextRevision(address, session))
                if session.changes[address] == versions[address] { self.adoptFiles(queue, session) }
            }
        }
        try await operation.value
    }

    @discardableResult private func enqueue(
        _ session: Session, _ operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Error> {
        let previous = session.tail
        let task = Task { @MainActor in
            _ = await previous?.result
            guard !session.closed else { throw AttachmentDraftError.staleAccess }
            do {
                try await operation()
                session.errorMessage = nil
                self.publish(session)
            } catch {
                session.errorMessage = error.localizedDescription
                self.publish(session)
                throw error
            }
        }
        session.tail = task
        return task
    }
    private func finishDelivered(_ session: Session) async throws {
        guard let access = session.access else { return }
        for (url, address) in Array(session.delivered) {
            try await store.confirmSent(
                url: url, address: address, access: access, revision: nextRevision(address, session))
            session.delivered[url] = nil
        }
    }
    private func nextRevision(_ address: AttachmentDraftAddress, _ session: Session) throws -> UInt64 {
        let previous = session.revisions[address] ?? 0
        guard previous < UInt64.max else { throw AttachmentDraftError.staleRevision }
        let revision = previous + 1
        session.revisions[address] = revision
        return revision
    }
    private func adoptFiles(_ queue: AttachmentDraftQueue, _ session: Session) {
        session.files[queue.address] = queue.files.filter { file in
            file.url.map { !session.confirmed.contains($0) } ?? true
        }.map { file in
            guard let url = file.url, session.inFlight.contains(url) else { return file }
            return AttachmentDraftFile(
                id: file.id, filename: file.filename, byteCount: file.byteCount, url: url, phase: .ready,
                errorMessage: file.errorMessage)
        }
    }
    private func markInterrupted(_ urls: Set<URL>, _ session: Session) {
        for address in Array(session.files.keys) {
            session.files[address] = session.files[address, default: []].map { file in
                guard let url = file.url, urls.contains(url) else { return file }
                session.reviewed.remove(file.id)
                return AttachmentDraftFile(
                    id: file.id, filename: file.filename, byteCount: file.byteCount, url: url, phase: .interrupted,
                    errorMessage: file.errorMessage)
            }
        }
    }
    private func publish(_ session: Session) {
        guard current === session else { return }
        queues = session.queues
        files = session.files
        errorMessage = session.errorMessage
    }
}
