import Foundation

enum MatrixID {
    /// Untrusted IDs from storage, notifications or the server: the sigil, at least one character after it,
    /// a bounded length and no control characters. Pass "" when any sigil is acceptable.
    static func isValid(_ value: String, sigil: String) -> Bool {
        value.hasPrefix(sigil) && value.utf8.count > sigil.utf8.count && value.utf8.count <= 2_048
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// A user ID as people write it in a message: localpart, server name and an optional port.
    static let userPattern =
        "@[A-Za-z0-9._=/+\\-]+:(?:\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9](?:[A-Za-z0-9.\\-]*[A-Za-z0-9])?)(?::[0-9]{1,5})?"

    static func isUser(_ value: String) -> Bool {
        value.range(of: "^" + userPattern + "$", options: .regularExpression) != nil
    }

    static func localpart(_ userID: String) -> String { String(userID.dropFirst().prefix { $0 != ":" }) }

    /// Where a mention of this person links, as Element writes it.
    static func permalink(_ userID: String) -> String {
        "https://matrix.to/#/" + (userID.addingPercentEncoding(withAllowedCharacters: permalinkCharacters) ?? userID)
    }
    private static let permalinkCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@:._=-/+")
}
