import Foundation

enum MatrixID {
    /// Untrusted IDs from storage, notifications or the server: the sigil, at least one character after it,
    /// a bounded length and no control characters. Pass "" when any sigil is acceptable.
    static func isValid(_ value: String, sigil: String) -> Bool {
        value.hasPrefix(sigil) && value.utf8.count > sigil.utf8.count && value.utf8.count <= 2_048
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
