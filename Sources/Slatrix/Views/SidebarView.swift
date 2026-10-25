import SwiftUI

struct SidebarView: View {
    private static let dot: CGFloat = 6
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    @EnvironmentObject var appearance: AppearanceStore
    @Binding var route: AppRoute
    @Binding var workspaceID: String?
    @Binding var search: String
    var draftRoomIDs: Set<String>
    var draftCount: Int? = nil
    var onSelect: (String) -> Void
    var onCreate: (CreationKind) -> Void
    var onPreferences: () -> Void
    var onMarkUnread: (ChatRoom) -> Void
    var onMarkRead: (ChatRoom) -> Void
    var onInviteWorkspace: (String) -> Void
    var onEditWorkspace: (String) -> Void
    var onNotifications: (String) -> Void
    var listWidth: CGFloat = 280
    /// ⇧⌘D hides the conversation list; the rail stays, as in Slack.
    var listHidden = false
    var onBrowseChannels: () -> Void
    @State private var collapsed: Set<String> = []
    private var colors: AppColors { appearance.colors }
    private var workspace: Workspace? { matrix.workspaces.first { $0.id == workspaceID } }
    private var hasUnreadActivity: Bool {
        matrix.rooms.contains { room in
            (room.isSpace && room.membership == "invite")
                || (room.membership != "leave"
                    && (room.isDirect || workspaceID == nil || room.spaceIDs.contains(workspaceID!))
                    && (room.hasUnread || room.membership == "invite"))
        }
    }
    private var visibleRooms: [ChatRoom] {
        matrix.rooms.filter { room in
            !room.isSpace && (room.isDirect || workspaceID == nil || room.spaceIDs.contains(workspaceID!))
                && (search.isEmpty || room.name.localizedCaseInsensitiveContains(search)) && room.membership != "leave"
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        HStack(spacing: 0) {
            rail
            if !listHidden { list }
        }.foregroundStyle(colors.text)
    }
    private var list: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: m.sp8) {
                Image(systemName: "line.3.horizontal.decrease").font(m.font(.body))
                TextField("Find a conversation…", text: $search).textFieldStyle(.plain).font(m.font(.secondary))
            }
            .padding(.horizontal, m.sp12).frame(height: m.control).background(
                colors.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: m.radiusLarge)
            ).overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border)).padding(
                .horizontal, m.sp12
            ).padding(.bottom, m.sp16)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    shortcut(.threads, label: "Threads", count: nil)
                    shortcut(
                        .drafts, label: "Drafts",
                        count: (draftCount ?? draftRoomIDs.count) == 0 ? nil : (draftCount ?? draftRoomIDs.count))
                    shortcut(.directory, label: "People", count: nil)
                    Divider().overlay(colors.border).padding(.horizontal, m.sp12).padding(.vertical, m.sp12)
                    if visibleRooms.contains(where: \.favorite) {
                        roomSection("Starred", symbol: "star", rooms: visibleRooms.filter(\.favorite))
                    }
                    roomSection(
                        "Channels", symbol: "number", rooms: visibleRooms.filter { !$0.isDirect && !$0.favorite })
                    Button(action: onBrowseChannels) {
                        Label("Browse channels", systemImage: "magnifyingglass").font(m.font(.body)).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).padding(.leading, m.sp32).frame(height: m.row)
                    }.buttonStyle(.row).foregroundStyle(colors.muted).padding(.horizontal, m.sp8)
                    roomSection(
                        "Direct messages", symbol: "bubble.left.and.bubble.right",
                        rooms: visibleRooms.filter { $0.isDirect && !$0.favorite })
                    Button {
                        onCreate(.directMessage)
                    } label: {
                        Label("Add teammates", systemImage: "plus").font(m.font(.body)).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).padding(.leading, m.sp32).frame(height: m.row)
                    }.buttonStyle(.row).foregroundStyle(colors.muted).padding(.horizontal, m.sp8)
                }.padding(.bottom, m.sp24)
            }.scrollIndicators(.hidden)
                .loadingInterval(
                    .sidebarLoading, while: matrix.rooms.isEmpty && matrix.status != .ready && !matrix.isPreview
                )
                .onChange(of: matrix.rooms.isEmpty, initial: true) { _, empty in
                    if !empty { Performance.finishOnScreen(.launchRooms, ["rooms": matrix.rooms.count]) }
                }
            // Silent while connected, like Slack; only trouble earns a line.
            if !matrix.isPreview && matrix.status != .ready {
                HStack(spacing: m.sp8) {
                    Circle().fill(.orange).frame(width: m(Self.dot), height: m(Self.dot))
                    Text(matrix.connectionDetail).font(m.font(.caption)).lineLimit(1)
                    Spacer()
                }.foregroundStyle(colors.muted).padding(.horizontal, m.sp16).padding(.vertical, m.sp12)
            }
        }.frame(width: listWidth).background(colors.sidebar)
    }
    private var header: some View {
        HStack(spacing: m.sp4) {
            Menu {
                if let workspace {
                    Button("Edit workspace details…") { onEditWorkspace(workspace.id) }
                        .disabled(matrix.isPreview)
                    Button("Invite people to \(workspace.name)…") { onInviteWorkspace(workspace.id) }
                        .disabled(matrix.isPreview || workspace.canInvite == false)
                    Divider()
                }
                Button("Create a workspace…") { onCreate(.workspace) }
                Button("Join a channel or workspace…") { onCreate(.join) }
                Divider()
                Button("Preferences…") { onPreferences() }
            } label: {
                HStack(spacing: m.sp8) {
                    Text(workspace?.name ?? "All conversations").font(m.font(.title, .bold)).lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down").font(m.font(.caption, .semibold))
                }
            }
            // A borderless-button menu hands its label to AppKit, which moves the chevron before the name.
            .menuStyle(.button).buttonStyle(.row).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .help(workspace?.name ?? "All conversations")
            Spacer(minLength: m.sp2)
            IconButton(symbol: "gearshape", label: "Preferences", action: onPreferences)
            IconButton(symbol: "square.and.pencil", label: "New message") { onCreate(.directMessage) }
        }.foregroundStyle(colors.primaryText).padding(.horizontal, m.sp16).frame(height: m.paneHeader)
    }
    private var rail: some View {
        VStack(spacing: m.sp16) {
            // Tightens to fit, as Slack's rail does, and scrolls only once even that would push the window taller
            // than the screen.
            ViewThatFits(in: .vertical) {
                railItems
                ScrollView { railItems }.scrollIndicators(.hidden)
            }.frame(maxHeight: .infinity, alignment: .top)
            IconButton(symbol: appearance.mode == .dark ? "moon" : "sun.max", label: "Appearance") { onPreferences() }
                .padding(m.sp4).background(colors.primaryText.opacity(0.1), in: Circle())
            Menu {
                Text(matrix.user?.name ?? "Slatrix")
                if let id = matrix.user?.id { Text(id) }
                Divider()
                Button("Preferences…") { onPreferences() }
            } label: {
                AvatarView(
                    name: matrix.user?.name ?? "You", size: m.avatar, matrix: matrix, source: matrix.user?.avatarURL)
            }.menuStyle(.button).buttonStyle(.row).menuIndicator(.hidden).padding(.bottom, m.sp16)
        }.frame(width: m.rail).background(colors.frame)
    }
    private var railItems: some View {
        RailStack(spacing: m.sp16) {
            VStack(spacing: m.sp8) {
                ForEach(WorkspaceRail.entries(workspaces: matrix.workspaces, rooms: matrix.rooms), id: \.self) {
                    workspaceIcon($0)
                }
                IconButton(symbol: "plus", label: "Create a workspace", role: .header) {
                    onCreate(.workspace)
                }.padding(m.sp4).background(colors.primaryText.opacity(0.1), in: Circle())
            }
            Rectangle().fill(colors.border).frame(width: m.sp24, height: 1)
            ForEach([AppRoute.home, .directMessages, .activity, .files, .saved], id: \.self) { item in
                Button {
                    route = item
                } label: {
                    VStack(spacing: m.sp4) {
                        Image(systemName: item.symbol).font(
                            m.font(.header, route == item ? .semibold : .regular)
                        ).frame(width: m.sp40, height: m.control).background(
                            route == item ? colors.primaryText.opacity(0.17) : .clear,
                            in: RoundedRectangle(cornerRadius: m.radiusLarge)
                        ).overlay(alignment: .topTrailing) {
                            if item == .activity && hasUnreadActivity {
                                Circle().fill(colors.accent).frame(width: m(Self.dot), height: m(Self.dot))
                                    .padding(
                                        m.sp4
                                    ).accessibilityLabel(
                                        "Unread conversations or invitations")
                            }
                        }
                        Text(item.title).font(m.font(.caption, route == item ? .semibold : .medium))
                    }
                    .foregroundStyle(route == item ? colors.primaryText : colors.muted).frame(
                        maxWidth: .infinity)
                }.buttonStyle(.row).accessibilityLabel(item.title)
            }
        }.padding(.top, m.sp12)
    }
    /// Slack's workspace switcher: the space's avatar, ringed when selected, with its unread state when not.
    private func workspaceIcon(_ space: Workspace?) -> some View {
        let selected = workspaceID == space?.id
        let name = space?.name ?? "All conversations"
        let badge = selected ? WorkspaceRail.Badge.quiet : WorkspaceRail.badge(space?.id, rooms: matrix.rooms)
        let corner = m.avatar * 0.19
        return Button {
            workspaceID = space?.id
            route = .home
        } label: {
            Group {
                if let space {
                    AvatarView(name: space.name, size: m.avatar, matrix: matrix, source: space.avatarURL)
                } else {
                    Image(systemName: "tray.2").font(m.font(.title)).foregroundStyle(colors.primaryText).frame(
                        width: m.avatar, height: m.avatar
                    ).background(colors.primaryText.opacity(0.12), in: RoundedRectangle(cornerRadius: corner))
                }
            }
            .padding(m.sp4)
            .overlay(
                RoundedRectangle(cornerRadius: corner + m.sp4).stroke(
                    selected ? colors.primaryText : .clear, lineWidth: m.sp2)
            )
            .overlay(alignment: .topTrailing) {
                switch badge {
                case .mentions(let count):
                    Text("\(count)").font(m.font(.caption, .bold)).padding(.horizontal, m.sp4).padding(
                        .vertical, m.sp2
                    ).background(Color(hex: 0xbc4b62), in: Capsule()).foregroundStyle(.white)
                case .unread:
                    Circle().fill(colors.primaryText).frame(width: m(Self.dot) * 1.5, height: m(Self.dot) * 1.5)
                        .overlay(Circle().stroke(colors.frame, lineWidth: m.sp2))
                case .quiet: EmptyView()
                }
            }
        }.buttonStyle(.row).help(name)
            .accessibilityLabel(name)
            .accessibilityValue(
                {
                    switch badge {
                    case .mentions(let count): "\(count) \(count == 1 ? "mention" : "mentions")"
                    case .unread: "Unread messages"
                    case .quiet: ""
                    }
                }()
            )
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                if let space {
                    Button("Invite people to \(space.name)…") { onInviteWorkspace(space.id) }
                        .disabled(matrix.isPreview || space.canInvite == false)
                    Button("Edit workspace details…") { onEditWorkspace(space.id) }.disabled(matrix.isPreview)
                    Button("Notifications…") { onNotifications(space.id) }.disabled(matrix.isPreview)
                }
            }
    }
    private func shortcut(_ item: AppRoute, label: String, count: Int?) -> some View {
        Button {
            route = item
        } label: {
            HStack(spacing: m.sp12) {
                Image(systemName: item.symbol).font(m.font(.body)).frame(width: m.avatarSmall)
                Text(label).font(m.font(.body))
                Spacer()
                if let count { Text("\(count)").font(m.font(.caption, .bold)) }
            }
            .padding(.horizontal, m.sp16).frame(height: m.row).background(
                route == item ? colors.selection : .clear, in: RoundedRectangle(cornerRadius: m.radius))
        }.buttonStyle(.row).padding(.horizontal, m.sp8)
    }
    private func roomSection(_ title: String, symbol: String, rooms: [ChatRoom]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: m.sp8) {
                Button {
                    if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
                } label: {
                    HStack(spacing: m.sp8) {
                        Image(systemName: collapsed.contains(title) ? "chevron.right" : "chevron.down").font(
                            m.font(.caption, .bold)
                        ).frame(width: m.sp12)
                        Image(systemName: symbol).font(m.font(.body))
                        Text(title).font(m.font(.body))
                        Spacer()
                    }
                }.buttonStyle(.row)
                if title != "Starred" {
                    IconButton(symbol: "plus", label: "Add \(title.lowercased())", role: .meta) {
                        onCreate(title == "Channels" ? .channel : .directMessage)
                    }
                }
            }.foregroundStyle(colors.muted).padding(.leading, m.sp12).padding(.trailing, m.sp8).frame(height: m.control)
                .padding(.top, m.sp8)
            if !collapsed.contains(title) {
                ForEach(rooms) { room in roomRow(room) }
            }
        }
    }
    private func roomRow(_ room: ChatRoom) -> some View {
        Button {
            onSelect(room.id)
        } label: {
            HStack(spacing: m.sp8) {
                if room.isDirect {
                    AvatarView(name: room.name, size: m.avatarSmall, matrix: matrix, source: room.avatarURL)
                } else {
                    Image(systemName: room.isEncrypted ? "lock" : "number").font(m.font(.body)).frame(
                        width: m.avatarSmall
                    )
                    .foregroundStyle(room.hasUnread ? colors.primaryText : colors.muted)
                }
                Text(room.name).font(m.font(.body, room.hasUnread ? .bold : .regular)).lineLimit(1)
                    .truncationMode(.tail)
                if room.muted { Image(systemName: "bell.slash").font(m.font(.caption)).foregroundStyle(colors.muted) }
                Spacer(minLength: m.sp2)
                if draftRoomIDs.contains(room.id) {
                    Image(systemName: "pencil").font(m.font(.caption)).foregroundStyle(colors.muted)
                }
                if room.mentions > 0 {
                    Text("\(room.mentions)").font(m.font(.caption, .bold)).padding(.horizontal, m.sp4).padding(
                        .vertical, m.sp2
                    ).background(Color(hex: 0xbc4b62), in: Capsule()).foregroundStyle(.white)
                } else if room.unreadMessages > 0 || room.unread > 0 {
                    Text("\(max(room.unreadMessages, room.unread))").font(m.font(.caption, .bold))
                        .foregroundStyle(colors.primaryText)
                } else if room.isMarkedUnread {
                    Circle().fill(colors.primaryText).frame(width: m(Self.dot), height: m(Self.dot)).accessibilityLabel(
                        "Marked unread")
                }
            }.padding(.leading, m.sp32).padding(.trailing, m.sp12).frame(height: m.row)
                .background(
                    matrix.selectedRoomID == room.id && route == .home ? colors.selection : .clear,
                    in: RoundedRectangle(cornerRadius: m.radius)
                )
                .contentShape(Rectangle())
        }.buttonStyle(.row).padding(.horizontal, m.sp8).help(room.name)
            .contextMenu {
                Button("Mark unread") { onMarkUnread(room) }.disabled(matrix.isPreview || room.membership != "join")
                Button("Mark read") { onMarkRead(room) }.disabled(matrix.isPreview || room.membership != "join")
                Divider()
                Button(room.favorite ? "Remove from Starred" : "Move to Starred") {
                    Task {
                        do { try await matrix.setFavorite(room, value: !room.favorite) } catch {
                            matrix.errorMessage = MatrixService.safeError(error)
                        }
                    }
                }
                Button("Notifications…") { onNotifications(room.id) }.disabled(
                    matrix.isPreview || room.membership != "join")
            }
    }
}

/// A column whose gaps shrink, down to a quarter, to fit the height offered. Its ideal height is the tightest, so
/// `ViewThatFits` keeps it until even that overflows.
private struct RailStack: Layout {
    var spacing: CGFloat

    private func measure(_ subviews: Subviews) -> (heights: [CGFloat], gaps: CGFloat) {
        (subviews.map { $0.sizeThatFits(.unspecified).height }, CGFloat(max(subviews.count - 1, 0)))
    }

    private func gap(_ height: CGFloat?, _ subviews: Subviews) -> CGFloat {
        let (heights, gaps) = measure(subviews)
        guard let height, gaps > 0 else { return spacing / 4 }
        return min(max((height - heights.reduce(0, +)) / gaps, spacing / 4), spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (heights, gaps) = measure(subviews)
        let width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(
            width: proposal.width ?? width, height: heights.reduce(0, +) + gaps * gap(proposal.height, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let gap = gap(bounds.height, subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, measure(subviews).heights) {
            subview.place(
                at: CGPoint(x: bounds.midX, y: y), anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + gap
        }
    }
}
