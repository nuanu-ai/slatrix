#if DEBUG
import SwiftUI

/// Every design system component in every state, for review before screens adopt it. Debug builds only:
/// Window ▸ Component Gallery, and `SLATRIX_SNAPSHOTS=1 swift test --filter Snapshots` renders it.
struct ComponentGallery: View {
    static let width: CGFloat = 1180
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var matrix = MatrixService()
    @State private var people = PeopleService()

    var body: some View {
        let colors = appearance.colors
        VStack(alignment: .leading, spacing: m.sp40) {
            VStack(alignment: .leading, spacing: m.sp4) {
                Text("Slatrix design system").font(m.font(.display, .bold)).foregroundStyle(colors.textPrimary)
                Text("\(appearance.isDark ? "Dark" : "Light") · \(appearance.palette.name) · 100%")
                    .font(m.font(.secondary)).foregroundStyle(colors.textSecondary)
            }
            HStack(alignment: .top, spacing: m.sp40) {
                VStack(alignment: .leading, spacing: m.sp40) {
                    section("Color") { swatches }
                    section("Type") { typeScale }
                    section("Elevation") { elevation }
                }.frame(width: m(420), alignment: .leading)
                VStack(alignment: .leading, spacing: m.sp40) {
                    section("Buttons") { buttons }
                    section("Fields") { fields }
                    section("Avatars, badges and tags") { identity }
                    section("Section header") {
                        SectionHeader(title: "Channels", collapsed: false, onToggle: {}, addLabel: "Add channels") {
                            EmptyView()
                        }.frame(width: m(280)).background(appearance.colors.sidebar)
                    }
                    section("Loading") { loading }
                }
            }
            section("Profile") { profile }
            section("Files") { files }
            section("Modals, tabs and people") { modals }
        }
        .padding(m.sp40).frame(width: m(Self.width), alignment: .leading)
        .background(colors.canvas).foregroundStyle(colors.textBody)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: m.sp16) {
            Text(title).font(m.font(.title, .bold)).foregroundStyle(appearance.colors.textPrimary)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(m.font(.caption)).foregroundStyle(appearance.colors.textSecondary)
    }

    // MARK: Tokens

    private var swatches: some View {
        let c = appearance.colors
        let groups: [(String, [(String, Color)])] = [
            (
                "Text",
                [
                    ("primary", c.textPrimary), ("body", c.textBody), ("secondary", c.textSecondary),
                    ("tertiary", c.textTertiary),
                ]
            ),
            (
                "Surface",
                [
                    ("canvas", c.canvas), ("raised", c.raised), ("sunken", c.sunken), ("overlay", c.overlay),
                    ("sidebar", c.sidebar), ("frame", c.frame), ("scrim", c.scrim),
                ]
            ),
            (
                "Line and state",
                [
                    ("border", c.border), ("border strong", c.borderStrong), ("hover", c.hover),
                    ("pressed", c.pressed), ("selection", c.selection),
                    ("selection strong", c.selectionStrong), ("focus ring", c.focusRing),
                ]
            ),
            (
                "Accent and status",
                [
                    ("accent", c.accent), ("primary", c.buttonPrimary), ("destructive", c.destructive),
                    ("warning", c.warning), ("mention", c.mention), ("active", c.presenceActive),
                    ("away", c.presenceAway),
                ]
            ),
        ]
        return VStack(alignment: .leading, spacing: m.sp16) {
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: m.sp8) {
                    caption(group.0)
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(m(96)), spacing: m.sp8, alignment: .leading), count: 4),
                        alignment: .leading, spacing: m.sp8
                    ) {
                        ForEach(group.1, id: \.0) { swatch in
                            VStack(alignment: .leading, spacing: m.sp4) {
                                RoundedRectangle(cornerRadius: m.radius).fill(swatch.1).frame(height: m.sp32)
                                    .overlay(RoundedRectangle(cornerRadius: m.radius).strokeBorder(c.border))
                                caption(swatch.0)
                            }
                        }
                    }
                }
            }
        }
    }

    private var typeScale: some View {
        let roles: [(String, TextRole)] = [
            ("Hero 40", .hero), ("Display 28", .display), ("Header 22", .header), ("Title 18", .title),
            ("Body 15", .body), ("Secondary 13", .secondary), ("Meta 12", .meta), ("Caption 11", .caption),
        ]
        return VStack(alignment: .leading, spacing: m.sp8) {
            ForEach(roles, id: \.0) { role in
                HStack(alignment: .firstTextBaseline, spacing: m.sp12) {
                    caption(role.0).frame(width: m(80), alignment: .leading)
                    Text("Harbor").font(m.font(role.1, role.1.points >= 18 ? .bold : .regular))
                        .foregroundStyle(appearance.colors.textPrimary)
                }
            }
        }
    }

    private var elevation: some View {
        HStack(spacing: m.sp24) {
            ForEach([(Elevation.e1, "e1 toolbar"), (.e2, "e2 popover"), (.e3, "e3 modal")], id: \.1) { level in
                caption(level.1).frame(width: m(104), height: m(64))
                    .background(appearance.colors.overlay, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                    .elevation(level.0, cornerRadius: m.radiusLarge)
            }
        }.padding(.vertical, m.sp8)
    }

    // MARK: Components

    private var buttons: some View {
        let states = InteractionState.allCases
        return VStack(alignment: .leading, spacing: m.sp12) {
            HStack(spacing: m.sp12) {
                Color.clear.frame(width: m(84), height: 1)
                ForEach(states, id: \.self) { state in
                    caption("\(state)").frame(width: m(104), alignment: .leading)
                }
            }
            ForEach(ButtonKind.allCases, id: \.self) { kind in
                HStack(spacing: m.sp12) {
                    caption("\(kind)").frame(width: m(84), alignment: .leading)
                    ForEach(states, id: \.self) { state in
                        ButtonChrome(kind: kind, state: state) {
                            Text(kind == .destructive ? "Delete" : kind == .link ? "View all" : "Message")
                        }.font(m.font(.secondary)).frame(width: m(104), alignment: .leading)
                    }
                }
            }
            HStack(spacing: m.sp12) {
                caption("icon").frame(width: m(84), alignment: .leading)
                ForEach(states, id: \.self) { state in
                    IconChrome(state: state) {
                        Image(systemName: "bookmark").font(m.font(.title))
                            .frame(width: m.iconButton, height: m.iconButton)
                    }.frame(width: m(104), alignment: .leading)
                }
            }
            HStack(spacing: m.sp12) {
                caption("sizes").frame(width: m(84), alignment: .leading)
                ForEach([ControlSize.small, .regular, .large], id: \.self) { size in
                    ButtonChrome(kind: .primary, state: .rest) { Text("Sign in") }.controlSize(size)
                }
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            HStack(spacing: m.sp12) {
                FieldChrome(focused: false) { TextField("Channel name", text: .constant("")) }
                FieldChrome(focused: true) { TextField("Channel name", text: .constant("design-team")) }
            }
            HStack(spacing: m.sp12) {
                FieldChrome(focused: false, error: true) { TextField("Channel name", text: .constant("#?!")) }
                FieldChrome(focused: false) { TextField("Channel name", text: .constant("read only")) }
                    .disabled(true)
            }
            HStack(spacing: m.sp12) {
                SearchField(prompt: "Search Harbor", text: .constant(""), hint: "⌘ K")
                SearchField(prompt: "Find a member", text: .constant("julia"))
            }
        }.frame(width: m(560))
    }

    private var identity: some View {
        let c = appearance.colors
        return HStack(alignment: .center, spacing: m.sp20) {
            AvatarView(name: "Julia Park", size: m.avatarSmall)
            AvatarView(name: "Sam Ortiz", size: m.avatarMedium, presence: .active)
            AvatarView(name: "Alex Rivera", size: m.avatar, presence: .active)
            AvatarView(name: "Mina Cho", size: m.avatar, presence: .away)
            AvatarView(name: "Harbor", size: m.avatarLarge, presence: .active)
            CountBadge(text: "3")
            CountBadge(text: "99+")
            TagLabel(text: "You")
            TagLabel(text: "Invited")
            Circle().fill(c.mention).frame(width: m(9), height: m(9))
        }
    }

    /// Type tiles for every kind, and a card as a row shows it. Inline images and the viewer are in the snapshots.
    private var files: some View {
        let attachment = MessageAttachment(
            name: "Brand guidelines.pdf", url: "mxc://harbor.example/guidelines", mimeType: "application/pdf",
            size: 2_400_000)
        let message = ChatMessage(
            id: "$guidelines", roomID: "!design:harbor.example", senderID: "@julia:harbor.example",
            senderName: "Julia Park", body: attachment.name, timestamp: .now, kind: "m.file", attachment: attachment)
        return HStack(alignment: .top, spacing: m.sp40) {
            HStack(alignment: .top, spacing: m.sp16) {
                ForEach(FileKind.allCases, id: \.self) { kind in
                    VStack(spacing: m.sp4) {
                        FileTypeIcon(kind: kind)
                        caption(kind.label)
                    }
                }
            }
            AttachmentView(matrix: matrix, message: message, attachment: attachment).frame(width: m(420))
        }
    }

    /// Skeleton rows only: the spinner never stops moving, so a snapshot of it never settles.
    private var loading: some View {
        SkeletonRows(count: 2).frame(width: m(420), height: m(132))
            .background(appearance.colors.canvas, in: RoundedRectangle(cornerRadius: m.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).strokeBorder(appearance.colors.border))
    }

    private var modals: some View {
        HStack(alignment: .top, spacing: m.sp40) {
            ConfirmModal(
                title: "Delete message?", message: "This can’t be undone.", action: "Delete", onConfirm: {},
                onCancel: {}
            )
            .padding(-m.sp40)
            VStack(alignment: .leading, spacing: m.sp24) {
                TabBar(
                    tabs: [
                        .init(value: 0, title: "About"), .init(value: 1, title: "Members", count: 12),
                        .init(value: 2, title: "Settings"),
                    ], selection: .constant(1))
                VStack(spacing: 0) {
                    PersonRow(name: "Julia Park", userID: "@julia:harbor.example", presence: .active) {}
                    PersonRow(name: "Sam Ortiz", userID: "@sam:harbor.example", isYou: true, presence: .away) {}
                }.frame(width: m(400))
            }
        }
    }

    private var profile: some View {
        let person = ChatUser(id: "@julia:harbor.example", name: "Julia Park")
        return HStack(alignment: .top, spacing: m.sp40) {
            VStack(alignment: .leading, spacing: m.sp8) {
                caption("Card, beside a click on a name or photo")
                PopoverSurface {
                    ProfileCard(
                        matrix: matrix, people: people, userID: person.id, fallback: person,
                        onOpenConversation: { _ in }, onViewProfile: {})
                }
            }
            VStack(alignment: .leading, spacing: m.sp8) {
                caption("Full profile pane")
                ProfilePane(
                    matrix: matrix, people: people, userID: person.id, fallback: person,
                    onOpenConversation: { _ in }, onClose: {}
                )
                .frame(width: m(336), height: m(640))
                .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).strokeBorder(appearance.colors.border))
                .clipShape(RoundedRectangle(cornerRadius: m.radiusLarge))
            }
        }
    }
}
#endif
