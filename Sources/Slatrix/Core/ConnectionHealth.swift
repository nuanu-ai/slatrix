import Foundation

enum ConnectionHealth: String, Codable {
    case connecting, connected, offline, reconnecting, paused

    static func resolve(
        network: Bool?, foreground: Bool = true, running: Bool, responded: Bool,
        interrupted: Bool, previouslyConnected: Bool
    ) -> Self {
        if !foreground { return .paused }
        if network == false { return .offline }
        if running && responded { return .connected }
        if interrupted || previouslyConnected { return .reconnecting }
        return .connecting
    }

    var label: String {
        switch self {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .offline: "You’re offline"
        case .reconnecting: "Reconnecting…"
        case .paused: "Paused"
        }
    }
    var notice: String? { self == .connected || self == .paused ? nil : label }

    static func bannerText(notice: String?, queuedCount: Int) -> String? {
        guard let notice else { return nil }
        guard queuedCount > 0 else { return notice }
        let noun = queuedCount == 1 ? "message" : "messages"
        return "\(notice) · \(queuedCount) \(noun) will send when you reconnect"
    }
}
