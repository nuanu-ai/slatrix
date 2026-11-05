import AppKit
import SwiftUI

/// The sidebar: a panel inset in the window, with the window buttons on top, the space's name and its menu, the
/// shortcuts, the conversations, and you at the bottom.
struct SidebarView: View {
    let matrix: MatrixService
    @EnvironmentObject var appearance: AppearanceStore
    @Binding var route: AppRoute
    @Binding var workspaceID: String?
    /// "Find a DM" and the Unreads switch of the DMs list, which takes the column while DMs is picked.
    @Binding var directMessageSearch: String
    @Binding var unreadDirectMessagesOnly: Bool
    var draftRoomIDs: Set<String>
    var draftCount: Int? = nil
    var onSelect: (String) -> Void
    var onCreate: (CreationKind) -> Void
    var onPreferences: () -> Void
    var onProfile: () -> Void
    var onSignOut: () -> Void
    var onMarkUnread: (ChatRoom) -> Void
    var onMarkRead: (ChatRoom) -> Void
    var onInviteWorkspace: (String) -> Void
    var onEditWorkspace: (String) -> Void
    var onNotifications: (String) -> Void
    var onHide: () -> Void
    /// Set while an update waits or in the preview, for the button beside you at the bottom.
    var accessory: (title: String, action: () -> Void)? = nil
    var onBrowseChannels: () -> Void
    /// Section titles folded shut; held by the window, so they survive the sidebar moving into the drawer and back.
    @Binding var collapsed: Set<String>
    @Environment(\.metrics) private var m
    private var colors: AppColors { appearance.colors }
    private var workspace: Workspace? { matrix.workspaces.first { $0.id == workspaceID } }
    private var activityCount: Int {
        let rooms = matrix.rooms.filter { room in
            room.isSpace
                ? room.membership == "invite"
                : WorkspaceMembership.includes(direct: room.isDirect, spaceIDs: room.spaceIDs, spaceID: workspaceID)
        }
        let ids = Set(rooms.map(\.id))
        return ActivityBadge.count(rooms: rooms, items: matrix.activity.items.filter { ids.contains($0.roomID) })
    }
    private var visibleRooms: [ChatRoom] {
        matrix.rooms.filter { room in
            !room.isSpace
                && WorkspaceMembership.includes(direct: room.isDirect, spaceIDs: room.spaceIDs, spaceID: workspaceID)
                && room.membership != "leave"
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // The window buttons are AppKit's and sit here, over the panel.
                Spacer()
                IconButton(symbol: "sidebar.left", label: "Hide sidebar", role: .body, action: onHide)
                    .foregroundStyle(colors.textSecondary)
            }.frame(height: m.paneHeader - m.sidebarInset).background(WindowDragArea())
            if route == .directMessages {
                DirectMessagesColumn(
                    matrix: matrix, search: $directMessageSearch, unreadOnly: $unreadDirectMessagesOnly,
                    onSelect: onSelect, onCompose: { onCreate(.directMessage) })
            } else {
                header
                list
            }
        }
        .padding(.horizontal, m.sp8)
        // The list scrolls on under you, through the bar's material.
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(colors.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: m.radiusPanel))
        .elevation(.e1, cornerRadius: m.radiusPanel)
        .foregroundStyle(colors.textBody)
    }

    private var list: some View {
        let visibleRooms = visibleRooms
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                shortcut(.activity, label: "Activity", badge: activityCount)
                shortcut(.threads, label: "Threads")
                shortcut(.saved, label: "Later", count: matrix.savedMessages.list.saved.count)
                shortcut(.drafts, label: "Drafts", count: draftCount ?? draftRoomIDs.count)
                if visibleRooms.contains(where: \.favorite) {
                    roomSection("Starred", rooms: visibleRooms.filter(\.favorite)) { EmptyView() }
                }
                roomSection(
                    "Channels", rooms: visibleRooms.filter { !$0.isDirect && !$0.favorite },
                    add: ("Add channels", .channel)
                ) {
                    Button("Create a channel…") { onCreate(.channel) }
                    Button("Browse channels…", action: onBrowseChannels)
                }
                roomSection(
                    "Direct messages", rooms: visibleRooms.filter { $0.isDirect && !$0.favorite },
                    add: ("New message", .directMessage)
                ) {
                    Button("New message…") { onCreate(.directMessage) }
                    Button("Browse people…") { route = .directory }
                }
            }.padding(.top, m.sp8).padding(.bottom, m.sp20)
        }.scrollIndicators(.hidden)
            .loadingInterval(.sidebarLoading, while: !matrix.roomsLoaded)
            .onChange(of: matrix.rooms.isEmpty, initial: true) { _, empty in
                if !empty { Performance.finishOnScreen(.launchRooms, ["rooms": matrix.rooms.count]) }
            }
    }

    /// The space's name, which opens the spaces menu, and a new message.
    private var header: some View {
        HStack(spacing: m.sp4) {
            SpacesMenu(
                matrix: matrix, workspaceID: workspaceID,
                onSelect: {
                    workspaceID = $0
                    route = .home
                }, onCreate: onCreate, onInvite: onInviteWorkspace, onEdit: onEditWorkspace)
            Spacer(minLength: m.sp2)
            IconButton(symbol: "square.and.pencil", label: "New message", role: .body) { onCreate(.directMessage) }
                .foregroundStyle(colors.textSecondary)
        }.padding(.leading, m.sp8).frame(height: m.control)
    }

    /// You, with your status, Preferences and signing out; and an update or the preview's way out beside you.
    private var footer: some View {
        HStack(spacing: m.sp8) {
            Menu {
                Text(matrix.user?.name ?? "Slatrix")
                if let id = matrix.user?.id { Text(id) }
                Divider()
                Button("Profile", action: onProfile)
                Button("Preferences…") { onPreferences() }
                Divider()
                Button(matrix.isPreview ? "Leave preview" : "Sign out", action: onSignOut)
            } label: {
                HStack(spacing: m.sp8) {
                    AvatarView(
                        name: matrix.user?.name ?? "You", size: m.avatarMedium, presence: .active,
                        surface: colors.sidebar, matrix: matrix, source: matrix.user?.avatarURL)
                    Text(matrix.user?.name ?? "You").font(m.font(.body)).foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.leading, m.sp8).frame(height: m.controlLarge).modifier(SidebarRowFill(selected: false))
            }.menuStyle(.button).buttonStyle(.row).menuIndicator(.hidden)
                .accessibilityLabel("Your profile and status")
            if let accessory {
                Button(accessory.title, action: accessory.action).buttonStyle(.primary).controlSize(.small)
            }
        }.padding(.horizontal, m.sp8).padding(.vertical, m.sp8)
            .modifier(FooterPlate())
    }

    /// You, on a glass plate the list scrolls under, as macOS 26 floats its chrome; a bar with a hairline before it.
    private struct FooterPlate: ViewModifier {
        @Environment(\.metrics) private var m
        @EnvironmentObject private var appearance: AppearanceStore
        func body(content: Content) -> some View {
            if #available(macOS 26, *) {
                content.glass(
                    appearance.colors.sidebar, in: RoundedRectangle(cornerRadius: m.radiusLarge),
                    cornerRadius: m.radiusLarge
                ).padding(m.sp8).scrollEdge(.bottom, appearance.colors.sidebar)
            } else {
                content.background(.bar).overlay(alignment: .top) {
                    VStack(spacing: 0) { Divider().overlay(appearance.colors.border) }
                }
            }
        }
    }

    private func shortcut(_ item: AppRoute, label: String, badge: Int = 0, count: Int = 0) -> some View {
        let selected = route == item
        return Button {
            route = item
        } label: {
            HStack(spacing: m.sp8) {
                // In the accent, as Mail's mailboxes are.
                Image(systemName: item.symbol).font(m.font(.body)).frame(width: m.sp16)
                    .foregroundStyle(colors.accent)
                Text(label).font(m.font(.body))
                Spacer(minLength: 0)
                if badge > 0 {
                    CountBadge(text: UnreadBadge.label(badge))
                } else if count > 0 {
                    Text("\(count)").font(m.font(.subheadline)).monospacedDigit().foregroundStyle(colors.textSecondary)
                        .padding(.trailing, m.sp2)
                }
            }
            .foregroundStyle(colors.textPrimary)
            .padding(.horizontal, m.sp8).frame(height: m.row)
            .modifier(SidebarRowFill(selected: selected))
        }.buttonStyle(.row).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func roomSection(
        _ title: String, rooms: [ChatRoom], add: (label: String, kind: CreationKind)? = nil,
        @ViewBuilder menu: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: title, collapsed: collapsed.contains(title),
                onToggle: {
                    if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
                }, addLabel: add?.label, onAdd: { add.map { onCreate($0.kind) } }, menu: menu
            ).padding(.top, m.sp12)
            let selectedID = route == .home ? matrix.selectedRoomID : nil
            ForEach(SidebarLayout.sectionRooms(rooms, collapsed: collapsed.contains(title), selectedID: selectedID)) {
                room in
                SidebarRoomRow(
                    room: room, selected: selectedID == room.id, hasDraft: draftRoomIDs.contains(room.id),
                    isPreview: matrix.isPreview, matrix: matrix, onSelect: onSelect, onMarkUnread: onMarkUnread,
                    onMarkRead: onMarkRead, onNotifications: onNotifications
                ).equatable()
            }
        }
    }
}

/// The space's name at the top of the sidebar, opening a menu of every space, ⌘1–⌘9 beside each, with what to do
/// in this one. A dot marks unread messages in the others.
private struct SpacesMenu: View {
    let matrix: MatrixService
    let workspaceID: String?
    let onSelect: (String?) -> Void
    let onCreate: (CreationKind) -> Void
    let onInvite: (String) -> Void
    let onEdit: (String) -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    private func item(_ space: Workspace?, index: Int, colors: AppColors) -> some View {
        let badge: UnreadBadge = space?.id == workspaceID ? .none : WorkspaceRail.badge(space?.id, rooms: matrix.rooms)
        let name = space?.name ?? "All conversations"
        let title: String = if case .count(let count) = badge { "\(name)  \(count)" } else { name }
        let key: KeyEquivalent? = index < 9 ? KeyEquivalent(Character("\(index + 1)")) : nil
        return Toggle(isOn: Binding(get: { space?.id == workspaceID }, set: { _ in onSelect(space?.id) })) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: SpaceTile.image(space, unread: badge != .none, matrix: matrix, colors: colors))
            }
        }.keyboardShortcut(key.map { KeyboardShortcut($0) })
    }

    var body: some View {
        let colors = appearance.colors
        let entries = WorkspaceRail.entries(workspaces: matrix.workspaces, rooms: matrix.rooms)
        let current = matrix.workspaces.first { $0.id == workspaceID }
        let othersUnread = entries.contains {
            $0?.id != workspaceID && WorkspaceRail.badge($0?.id, rooms: matrix.rooms) != .none
        }
        Menu {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, space in
                item(space, index: index, colors: colors)
            }
            Divider()
            if let current {
                Button("Invite people to \(current.name)…") { onInvite(current.id) }
                    .disabled(matrix.isPreview || current.canInvite == false)
                Button("Space settings…") { onEdit(current.id) }.disabled(matrix.isPreview)
                Divider()
            }
            Button("Create a space…") { onCreate(.workspace) }
            Button("Join a space…") { onCreate(.join) }
        } label: {
            HStack(spacing: m.sp4) {
                Text(current?.name ?? "All conversations").font(m.font(.title3, .semibold))
                    .foregroundStyle(colors.textPrimary).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(m.font(.subheadline, .semibold))
                    .foregroundStyle(colors.textSecondary)
                if othersUnread {
                    Circle().fill(colors.accentFill).frame(width: m(6), height: m(6))
                }
            }
        }
        // A borderless-button menu hands its label to AppKit, which moves the chevron before the name.
        .menuStyle(.button).buttonStyle(.row).menuIndicator(.hidden).fixedSize()
        .help("Switch space")
        .accessibilityLabel(
            "\(current?.name ?? "All conversations"), switch space"
                + (othersUnread ? ", other spaces have unread messages" : ""))
    }
}

/// A space's tile for a menu item, which takes only an image: its photo or initial on its color, with a dot while
/// it has unread messages.
@MainActor enum SpaceTile {
    static func image(_ space: Workspace?, unread: Bool, matrix: MatrixService, colors: AppColors) -> NSImage {
        let side: CGFloat = 18
        let photo = space?.avatarURL.flatMap { matrix.isPreview ? nil : matrix.avatarImages.cachedImage(for: $0) }
        let fill = space.map { NSColor(avatarColor($0.name)) } ?? NSColor(colors.sunken)
        let accent = NSColor(colors.accentFill)
        let letter = space.map { String(initials($0.name).prefix(1)) } ?? "∗"
        let letterColor = NSColor(space == nil ? colors.textSecondary : colors.onAccent)
        let image = NSImage(size: NSSize(width: side + (unread ? 4 : 0), height: side), flipped: false) { _ in
            let tile = NSRect(x: 0, y: 0, width: side, height: side)
            let shape = NSBezierPath(roundedRect: tile, xRadius: 5, yRadius: 5)
            if let photo {
                NSGraphicsContext.current?.saveGraphicsState()
                shape.addClip()
                NSGraphicsContext.current?.cgContext.draw(photo, in: tile)
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                fill.setFill()
                shape.fill()
                let text = NSAttributedString(
                    string: letter,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: letterColor,
                    ])
                let size = text.size()
                text.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
            }
            if unread {
                accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: side - 2, y: side - 6, width: 6, height: 6)).fill()
            }
            return true
        }
        return image
    }
}

/// One conversation in the sidebar. Equal while what it shows is, so a change to one room redraws one row.
private struct SidebarRoomRow: View, Equatable {
    let room: ChatRoom
    let selected: Bool
    let hasDraft: Bool
    let isPreview: Bool
    let matrix: MatrixService
    let onSelect: (String) -> Void
    let onMarkUnread: (ChatRoom) -> Void
    let onMarkRead: (ChatRoom) -> Void
    let onNotifications: (String) -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.room == rhs.room && lhs.selected == rhs.selected && lhs.hasDraft == rhs.hasDraft
            && lhs.isPreview == rhs.isPreview
    }

    var body: some View {
        let badge = UnreadBadge(room)
        Button {
            onSelect(room.id)
        } label: {
            HStack(spacing: m.sp8) {
                if room.isDirect {
                    AvatarView(
                        name: room.name, size: m.avatarSmall, matrix: matrix, source: room.avatarURL
                    ).opacity(room.muted && !selected ? 0.5 : 1)
                } else {
                    Image(systemName: room.channelSymbol).font(m.font(.body)).frame(width: m.sp16)
                        .foregroundStyle(room.muted && !selected ? colors.textTertiary : colors.accent)
                }
                Text(room.name).font(m.font(.body, badge != .none ? .semibold : .regular)).lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: m.sp2)
                if hasDraft { Image(systemName: "pencil").font(m.font(.subheadline)) }
                if case .count(let count) = badge { CountBadge(text: count) }
            }
            .foregroundStyle(room.muted && !selected ? colors.textSecondary : colors.textPrimary)
            .padding(.leading, room.isDirect ? m.sp4 : m.sp8).padding(.trailing, m.sp8).frame(height: m.row)
            .modifier(SidebarRowFill(selected: selected))
        }.buttonStyle(.row).help(room.name)
            // The pointer rests on a row before the click; opening the timeline then hides its cache read.
            .onHover { if $0 { matrix.prepareRoom(room.id) } }
            .accessibilityAddTraits(selected ? .isSelected : [])
            // Bold, dimming and the lock don't reach VoiceOver.
            .accessibilityValue(
                [
                    room.isPrivate && !room.isDirect ? "Private channel" : nil, badge != .none ? "Unread" : nil,
                    room.muted ? "Muted" : nil,
                ].compactMap(\.self).joined(separator: ", ")
            )
            .contextMenu {
                if room.hasUnread {
                    Button("Mark as read") { onMarkRead(room) }.disabled(isPreview || room.membership != "join")
                } else {
                    Button("Mark as unread") { onMarkUnread(room) }.disabled(isPreview || room.membership != "join")
                }
                Divider()
                let noun = room.isDirect ? "conversation" : "channel"
                Button(room.favorite ? "Unstar \(noun)" : "Star \(noun)") {
                    Task {
                        do { try await matrix.setFavorite(room, value: !room.favorite) } catch {
                            matrix.errorMessage = MatrixService.safeError(error)
                        }
                    }
                }
                Button("Notifications…") { onNotifications(room.id) }.disabled(
                    isPreview || room.membership != "join")
            }
    }
}

/// A sidebar row's fill: a quiet gray for the open one, a lighter one under the pointer. Hover is the row's own
/// state, so moving the pointer redraws one row, never the list.
struct SidebarRowFill: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    func body(content: Content) -> some View {
        content.background(
            selected ? appearance.colors.selection : hovering ? appearance.colors.hover : .clear,
            in: RoundedRectangle(cornerRadius: m.radius)
        ).onHover { hovering = $0 }
    }
}
