import Foundation

/// How Browse channels lays out a workspace: grouped by the space that lists each channel, the workspace's own first,
/// then nested spaces in the order the hierarchy lists them.
enum ChannelBrowser {
    enum Sort: String, CaseIterable {
        case name = "Name"
        case members = "Members"
    }

    struct Group: Equatable {
        var spaceName: String?
        var channels: [PublicDirectoryRoom]
    }

    static func groups(_ channels: [PublicDirectoryRoom], sort: Sort, hiding hidden: Set<String>) -> [Group] {
        var groups = [Group(spaceName: nil, channels: [])]
        for channel in channels where !hidden.contains(channel.id) {
            if let index = groups.firstIndex(where: { $0.spaceName == channel.spaceName }) {
                groups[index].channels.append(channel)
            } else {
                groups.append(Group(spaceName: channel.spaceName, channels: [channel]))
            }
        }
        return groups.filter { !$0.channels.isEmpty }.map { group in
            var group = group
            group.channels.sort { a, b in
                if sort == .members, a.joinedMembers != b.joinedMembers { return a.joinedMembers > b.joinedMembers }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
            return group
        }
    }
}
