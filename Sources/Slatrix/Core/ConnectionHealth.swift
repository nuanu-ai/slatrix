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
}
