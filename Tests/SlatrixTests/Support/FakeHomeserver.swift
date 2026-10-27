import Foundation
import Network

/// A homeserver on the loopback interface with one room, `room`, whose whole history is `messages`, newest first. It
/// answers just what a client needs to join that room and page back through it, so the real SDK can index synthetic
/// messages; anything else is "not found".
final class FakeHomeserver: @unchecked Sendable {
    let room: String
    private let messages: [[String: Any]]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeHomeserver")
    private(set) var url = ""

    init(room: String, messages: [[String: Any]]) async throws {
        self.room = room
        self.messages = messages
        listener = try NWListener(using: .tcp, on: .any)
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
                buffer = Data(buffer[(end.upperBound + length)...])
                let request = lines.first?.split(separator: " ").map(String.init) ?? []
                let (status, body) = respond(request.first ?? "", request.count > 1 ? request[1] : "")
                let json = try! JSONSerialization.data(withJSONObject: body)
                let head =
                    "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
                    + "Content-Type: application/json\r\nContent-Length: \(json.count)\r\n\r\n"
                connection.send(content: Data(head.utf8) + json, completion: .idempotent)
            }
            if done { connection.cancel() } else { read(connection, buffer) }
        }
    }

    private func respond(_ method: String, _ target: String) -> (Int, Any) {
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let segments = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if path == "/_matrix/client/versions" { return (200, ["versions": ["v1.11"]]) }
        // POST /_matrix/client/v3/rooms/{room}/join
        if method == "POST", segments.count == 6, segments[4] == room, segments[5] == "join" {
            return (200, ["room_id": room])
        }
        // GET /_matrix/client/v3/rooms/{room}/messages: everything in one page, then the start of the room.
        if segments.count == 6, segments[4] == room, segments[5] == "messages" {
            return target.contains("from=")
                ? (200, ["chunk": [], "start": "end"]) : (200, ["chunk": messages, "start": "start", "end": "end"])
        }
        return (404, ["errcode": "M_NOT_FOUND", "error": "Not found"])
    }
}
