enum WorkspaceMembership {
    static func includes(direct: Bool, spaceIDs: [String], spaceID: String?) -> Bool {
        direct || spaceID == nil || spaceIDs.contains(spaceID!)
    }
}
