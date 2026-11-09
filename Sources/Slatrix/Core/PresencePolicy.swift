/// A green dot when active, a hollow ring when away; nothing when unknown.
enum Presence: String, Decodable {
    case active, away
}

/// The dot on a person's picture, from the presence the server reports. A server with presence turned off reports
/// even you as offline while you're connected, so then nobody gets a dot.
enum PresencePolicy {
    /// `own` and `theirs` are Matrix presence states, nil when the server didn't answer.
    static func dot(own: String?, theirs: String?) -> Presence? {
        guard shared(own: own) else { return nil }
        return switch theirs {
        case "online": .active
        case "unavailable", "offline": .away
        default: nil
        }
    }

    static func shared(own: String?) -> Bool { own == "online" || own == "unavailable" }
}
