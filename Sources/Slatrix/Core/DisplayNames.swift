import Foundation

/// How a person is named everywhere, by the rules in `spec/display-names.json`.
enum DisplayNames {
    /// `userID`'s name: the room's `member` name, else their profile's `global` name, else their ID's localpart. A
    /// name the SDK finds `ambiguous`, or one that could pass for an ID or hides characters, carries the ID after it.
    static func name(_ userID: String, member: String?, global: String? = nil, ambiguous: Bool = false) -> String {
        func usable(_ name: String?) -> String? {
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != userID
            else { return nil }
            return name
        }
        guard let name = usable(member) ?? usable(global) else { return MatrixID.localpart(userID) }
        // The SDK's own tests for a name that could pass for someone else's.
        let suspicious =
            name.contains(#/@.+[:.].+/#)
            || name.unicodeScalars.contains {
                (0x2000...0x200D).contains($0.value) || (0x0300...0x036F).contains($0.value)
                    || [0x2062, 0x2063, 0x2800, 0x061C, 0xFEFF].contains($0.value)
            }
        return ambiguous || suspicious ? "\(name) (\(userID))" : name
    }
}
