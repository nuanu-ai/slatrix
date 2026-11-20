import Foundation
import Network

/// A loopback homeserver with one room. History is newest first, as returned by backward pagination.
final class FakeHomeserver: @unchecked Sendable {
    let room: String
    private var messages: [[String: Any]]
    private let dropFirstSendResponse: Bool
    private let refusesDeletions: Bool
    private let refusesEdits: Bool
    /// Answers deletions as if the access token had expired.
    private let rejectsTokenOnDeletions: Bool
    /// Deletions whose response waits for `releaseDeletions()`.
    private var heldDeletions: [() -> Void] = []
    private var holdsDeletions: Bool
    var deletionsHeld: Int { queue.sync { heldDeletions.count } }
    /// The bodies of the messages the room holds, oldest first.
    var bodies: [String] {
        queue.sync { messages.reversed().compactMap { ($0["content"] as? [String: Any])?["body"] as? String } }
    }
    private var fetchedEvents = 0
    /// How many single events clients asked for.
    var eventFetches: Int { queue.sync { fetchedEvents } }
    private var sent: [String: String] = [:]
    private var dropped: String?
    private var replayed = false
    var retriedDroppedSend: Bool { queue.sync { replayed } }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeHomeserver")
    private(set) var url = ""

    init(
        room: String, messages: [[String: Any]], dropFirstSendResponse: Bool = false, refusesDeletions: Bool = false,
        holdsDeletions: Bool = false, refusesEdits: Bool = false, rejectsTokenOnDeletions: Bool = false
    ) async throws {
        self.rejectsTokenOnDeletions = rejectsTokenOnDeletions
        self.dropFirstSendResponse = dropFirstSendResponse
        self.refusesDeletions = refusesDeletions
        self.holdsDeletions = holdsDeletions
        self.refusesEdits = refusesEdits
        self.room = room
        self.messages = messages
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: queue)
            read(connection, Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
        url = "http://127.0.0.1:\(port)"
    }

    deinit { listener.cancel() }

    /// Answers the deletions held so far, and every later one at once.
    func releaseDeletions() {
        queue.sync {
            holdsDeletions = false
            for answer in heldDeletions { answer() }
            heldDeletions = []
        }
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, error in
            guard error == nil else { return connection.cancel() }
            var buffer = received + (data ?? Data())
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n")
                let length =
                    lines.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard buffer.count >= end.upperBound + length else { break }
                let payload = Data(buffer[end.upperBound..<(end.upperBound + length)])
                buffer = Data(buffer[(end.upperBound + length)...])
                let request = lines.first?.split(separator: " ").map(String.init) ?? []
                let (method, target) = (request.first ?? "", request.count > 1 ? request[1] : "")
                let answer = { [self] in
                    guard let (status, body) = respond(method, target, payload) else { return connection.cancel() }
                    let json = try! JSONSerialization.data(withJSONObject: body)
                    let head =
                        "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
                        + "Content-Type: application/json\r\nContent-Length: \(json.count)\r\n\r\n"
                    connection.send(content: Data(head.utf8) + json, completion: .idempotent)
                }
                if holdsDeletions, method == "PUT", target.contains("/redact/") {
                    heldDeletions.append(answer)
                } else {
                    answer()
                }
            }
            if done { connection.cancel() } else { read(connection, buffer) }
        }
    }

    private func respond(_ method: String, _ target: String, _ payload: Data) -> (Int, Any)? {
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let segments = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if path == "/_matrix/client/versions" { return (200, ["versions": ["v1.11"]]) }
        // GET /_matrix/client/v3/profile/{user}[/{field}], which the app reads once signed in.
        if method == "GET", segments.count >= 5, segments[3] == "profile" { return (200, ["displayname": "Me"]) }
        // POST /_matrix/client/v3/rooms/{room}/join
        if method == "POST", segments.count == 6, segments[4] == room, segments[5] == "join" {
            return (200, ["room_id": room])
        }
        if method == "PUT", segments.count == 8, segments[4] == room, segments[5] == "send",
            segments[6] == "m.room.message",
            let content = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        {
            let transaction = segments[7]
            if refusesEdits, content["m.new_content"] != nil {
                return (403, ["errcode": "M_FORBIDDEN", "error": "Not allowed"])
            }
            if let eventID = sent[transaction] {
                if transaction == dropped { replayed = true }
                return (200, ["event_id": eventID])
            }
            let eventID = "$message-\(sent.count + 1)"
            sent[transaction] = eventID
            messages.insert(
                [
                    "type": "m.room.message", "event_id": eventID, "sender": "@me:localhost",
                    "origin_server_ts": sent.count, "content": content,
                ], at: 0)
            if dropFirstSendResponse, dropped == nil {
                dropped = transaction
                return nil
            }
            return (200, ["event_id": eventID])
        }
        // PUT /_matrix/client/v3/rooms/{room}/redact/{event}/{transaction}
        if method == "PUT", segments.count == 8, segments[4] == room, segments[5] == "redact" {
            if rejectsTokenOnDeletions { return (401, ["errcode": "M_UNKNOWN_TOKEN", "error": "Expired"]) }
            if refusesDeletions { return (403, ["errcode": "M_FORBIDDEN", "error": "Not allowed"]) }
            let redaction: [String: Any] = [
                "type": "m.room.redaction", "event_id": "$redaction-\(segments[7])", "sender": "@me:localhost",
                "origin_server_ts": messages.count + 1, "redacts": segments[6], "content": ["redacts": segments[6]],
            ]
            // As a server keeps a deleted message: its type and envelope, no content, and what deleted it.
            messages = messages.map { message in
                guard message["event_id"] as? String == segments[6] else { return message }
                return message.filter { ["type", "event_id", "sender", "origin_server_ts"].contains($0.key) }
                    .merging(["content": [:], "unsigned": ["redacted_because": redaction]]) { $1 }
            }
            return (200, ["event_id": redaction["event_id"]!])
        }
        // GET /_matrix/client/v3/rooms/{room}/event/{event}
        if method == "GET", segments.count == 7, segments[4] == room, segments[5] == "event" {
            fetchedEvents += 1
            guard let event = messages.first(where: { $0["event_id"] as? String == segments[6] }) else {
                return (404, ["errcode": "M_NOT_FOUND", "error": "Not found"])
            }
            return (200, event)
        }
        // GET /_matrix/client/v3/rooms/{room}/messages: everything in one page, then the start of the room.
        if segments.count == 6, segments[4] == room, segments[5] == "messages" {
            return target.contains("from=")
                ? (200, ["chunk": [], "start": "end"]) : (200, ["chunk": messages, "start": "start", "end": "end"])
        }
        return (404, ["errcode": "M_NOT_FOUND", "error": "Not found"])
    }
}
