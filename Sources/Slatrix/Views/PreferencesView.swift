import AppKit
import SwiftUI

struct PreferencesView: View {
    private static let size = CGSize(width: 848, height: 660)
    private static let navWidth: CGFloat = 188
    private static let miniatureHeight: CGFloat = 64
    private static let aboutIcon: CGFloat = 64
    private static let maxScopeTitleLength = 28
    @Environment(\.metrics) private var m
    @EnvironmentObject var appearance: AppearanceStore
    let matrix: MatrixService
    var onClose: () -> Void
    var onLogout: () -> Void
    var onRecovery: () -> Void
    var onEditProfile: () -> Void
    @State var tab = Tab.appearance
    var workspaceID: String? = nil
    var readOpenAtLogin: @Sendable () async -> Bool = { await PlatformIntegration.shared.loadOpenAtLogin() }
    @State private var themeScope = ThemeScope.all
    @State private var requestingNotifications = false
    @State private var notificationStatus: DesktopNotificationStatus?
    @State private var notificationStatusError: String?
    @State private var readingNotificationStatus = false
    @State private var notificationStatusRequest = UUID()
    @State private var notificationPermissionRequest = UUID()
    @State private var isPresented = false
    @State private var openAtLogin = false
    @State private var loginToggleEdited = false
    @State private var error: String?
    private var colors: AppColors { appearance.colors }

    private enum ThemeScope: Hashable {
        case all
        case workspace(String)
    }

    /// Resolves the open workspace against `matrix.workspaces` when present so leaving a space during sync cannot
    /// redirect edits to another workspace or silently write globally.
    private var activeWorkspace: (id: String, name: String)? {
        guard let workspaceID else { return nil }
        if let space = matrix.workspaces.first(where: { $0.id == workspaceID }) {
            return (space.id, space.name)
        }
        return nil
    }

    private var editedTheme: ColorTheme {
        if case .workspace(let boundID) = themeScope, activeWorkspace?.id == boundID {
            return appearance.effectiveTheme(for: boundID)
        }
        return appearance.theme
    }

    private func selectTheme(_ theme: ColorTheme) {
        switch themeScope {
        case .all:
            appearance.theme = theme
        case .workspace(let boundID):
            guard activeWorkspace?.id == boundID else {
                themeScope = .all
                return
            }
            appearance.setTheme(theme, for: boundID)
        }
    }

    private func truncatedTitle(_ name: String) -> String {
        if name.count <= Self.maxScopeTitleLength { return name }
        return String(name.prefix(Self.maxScopeTitleLength - 1)) + "…"
    }

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case appearance, notifications, account, advanced
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .appearance: "paintpalette"
            case .notifications: "bell"
            case .account: "person.crop.circle"
            case .advanced: "slider.horizontal.3"
            }
        }
    }
    private struct NotificationStatusContext: Hashable {
        let tab: Tab
        let session: UUID
    }
    private var notificationStatusContext: NotificationStatusContext {
        NotificationStatusContext(tab: tab, session: matrix.notificationSessionID)
    }

    var body: some View {
        Modal(
            title: "Preferences", size: .custom(Self.size.width), height: Self.size.height, padded: false,
            onClose: onClose
        ) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: m.sp4) {
                    ForEach(Tab.allCases) { item in
                        Button {
                            tab = item
                            error = nil
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .font(m.font(.body))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, m.sp12).frame(
                                    height: m.control
                                )
                                .foregroundStyle(tab == item ? colors.textPrimary : colors.textSecondary)
                                .modifier(SidebarRowFill(selected: tab == item))
                        }.buttonStyle(.row).accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                    Spacer()
                }.padding(m.sp12).frame(width: m(Self.navWidth)).background(colors.raised)
                Divider().overlay(colors.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: m.sp20) {
                        if let error {
                            InlineErrorView(message: error, dismiss: { self.error = nil }).clipShape(
                                RoundedRectangle(cornerRadius: m.radius))
                        }
                        switch tab {
                        case .appearance: appearancePane
                        case .notifications: notificationsPane
                        case .account: accountPane
                        case .advanced: advancedPane
                        }
                    }.padding(m.sp24).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.visible)
            }.overlay(alignment: .top) { Divider().overlay(colors.border) }
        }
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear {
            isPresented = true
            if let space = activeWorkspace, appearance.workspaceThemes[space.id] != nil {
                themeScope = .workspace(space.id)
            }
        }
        .task(id: tab) {
            guard tab == .advanced else { return }
            let enabled = await readOpenAtLogin()
            guard !Task.isCancelled, !loginToggleEdited else { return }
            openAtLogin = enabled
        }
        .onChange(of: activeWorkspace?.id) { _, currentID in
            if case .workspace(let boundID) = themeScope, currentID != boundID {
                themeScope = .all
            }
        }
        .task(id: notificationStatusContext) {
            notificationStatusRequest = UUID()
            readingNotificationStatus = false
            if tab == .notifications, !requestingNotifications { await refreshNotificationStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if tab == .notifications, !requestingNotifications { Task { await refreshNotificationStatus() } }
        }
        .onChange(of: matrix.notificationSessionID) { _, _ in
            notificationPermissionRequest = UUID()
            requestingNotifications = false
        }
        .onDisappear {
            isPresented = false
            notificationStatusRequest = UUID()
            notificationPermissionRequest = UUID()
            readingNotificationStatus = false
            requestingNotifications = false
        }
    }

    private var appearancePane: some View {
        let highContrast = appearance.effectiveIncreaseContrast
        return VStack(alignment: .leading, spacing: m.sp20) {
            VStack(alignment: .leading, spacing: m.sp12) {
                sectionTitle("Color mode")
                ChoiceGrid(minColumnWidth: m(142), spacing: m.sp12) {
                    ForEach([AppTheme.dark, .light, .system]) { mode in
                        let dark = mode == .dark || (mode == .system && appearance.systemIsDark)
                        choiceTile(label: mode.name, selected: appearance.mode == mode) {
                            appearance.mode = mode
                        } preview: {
                            AppMiniature(
                                colors: AppColors(
                                    dark: dark, accent: appearance.accent(dark: dark), theme: editedTheme,
                                    highContrast: highContrast),
                                split: mode == .system)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: m.sp16) {
                VStack(alignment: .leading, spacing: m.sp8) {
                    sectionTitle("Theme")
                    if let space = activeWorkspace {
                        workspaceScopeBar(space: space)
                    }
                }
                ForEach(ColorTheme.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: m.sp8) {
                        Text(group.title).font(m.font(.subheadline, .semibold)).foregroundStyle(colors.textSecondary)
                        ChoiceGrid(minColumnWidth: m(142), spacing: m.sp12) {
                            ForEach(group.themes) { theme in
                                choiceTile(label: theme.name, selected: editedTheme == theme) {
                                    selectTheme(theme)
                                } preview: {
                                    AppMiniature(
                                        colors: AppColors(
                                            dark: appearance.isDark, accent: appearance.accent(dark: appearance.isDark),
                                            theme: theme, highContrast: highContrast))
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: m.sp12) {
                    Toggle("Chat wallpaper", isOn: $appearance.chatWallpaper).toggleStyle(.switch).font(m.font(.body))
                    Toggle("Increase contrast", isOn: $appearance.increaseContrast).toggleStyle(.switch).font(
                        m.font(.body))
                }
            }
            Divider().overlay(colors.border)
            VStack(alignment: .leading, spacing: m.sp12) {
                sectionTitle("Message density")
                Picker("Message density", selection: $appearance.density) {
                    Text("Comfortable").tag(MessageDensity.comfortable)
                    Text("Compact").tag(MessageDensity.compact)
                }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().font(m.font(.body))
            }
            Toggle("Show profile photos in conversations", isOn: $appearance.showAvatars).toggleStyle(.switch).font(
                m.font(.body))
        }
    }

    @ViewBuilder private func workspaceScopeBar(space: (id: String, name: String)) -> some View {
        let canReset = themeScope == .workspace(space.id) && appearance.workspaceThemes[space.id] != nil
        let resetButton = Group {
            if canReset {
                Button("Use default") {
                    appearance.clearTheme(for: space.id)
                }.buttonStyle(.textLink).font(m.font(.subheadline)).fixedSize()
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: m.sp12) {
                    TabBar(
                        tabs: [
                            .init(value: ThemeScope.all, title: "All workspaces"),
                            .init(
                                value: ThemeScope.workspace(space.id), title: truncatedTitle(space.name),
                                accessibilityLabel: space.name),
                        ], selection: $themeScope)
                    Spacer(minLength: 0)
                    resetButton
                }
                VStack(alignment: .leading, spacing: m.sp4) {
                    scopeRow(title: "All workspaces", accessibleName: "All workspaces", scope: .all)
                    scopeRow(
                        title: space.name, accessibleName: space.name, scope: .workspace(space.id))
                    if canReset {
                        resetButton.padding(.top, m.sp4)
                    }
                }.padding(.bottom, m.sp8)
            }
            Divider().overlay(colors.border)
        }
    }

    private func scopeRow(title: String, accessibleName: String, scope: ThemeScope) -> some View {
        let selected = themeScope == scope
        return Button {
            themeScope = scope
        } label: {
            HStack(spacing: m.sp8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? colors.accent : colors.textSecondary)
                Text(title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected ? colors.textPrimary : colors.textSecondary)
                Spacer(minLength: 0)
            }
            .font(m.font(.body, selected ? .semibold : .regular))
            .padding(.horizontal, m.sp8).frame(height: m.row)
            .modifier(SidebarRowFill(selected: selected))
        }
        .buttonStyle(.row)
        .accessibilityLabel(accessibleName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var notificationsPane: some View {
        VStack(alignment: .leading, spacing: m.sp24) {
            Toggle(isOn: Binding(get: { appearance.notifications }, set: changeNotifications)) {
                sectionTitle("Desktop notifications")
            }.toggleStyle(.switch).disabled(requestingNotifications)
            if requestingNotifications {
                HStack(spacing: m.sp8) {
                    DelayedProgress()
                    Text("Waiting for macOS…")
                }.font(m.font(.subheadline))
            }
            macOSNotificationStatus
            Divider().overlay(colors.border)
            Toggle(isOn: $appearance.notificationPreview) {
                sectionTitle("Show message previews")
            }.toggleStyle(.switch).disabled(!appearance.notifications)
            Divider().overlay(colors.border)
            MatrixNotificationDefaultsSection(matrix: matrix)
        }
    }

    private var macOSNotificationStatus: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            HStack {
                Label("macOS", systemImage: "desktopcomputer").font(
                    m.font(.body, .semibold))
                Spacer()
                if readingNotificationStatus {
                    DelayedProgress().accessibilityLabel("Checking macOS notification settings")
                }
                Button("Refresh") { Task { await refreshNotificationStatus() } }.buttonStyle(.textLink)
                    .disabled(readingNotificationStatus || requestingNotifications)
            }
            if let notificationStatus {
                Text(notificationStatusTitle(notificationStatus)).font(m.font(.body))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notificationStatusError {
                Text(notificationStatusError).font(m.font(.subheadline)).foregroundStyle(colors.warning).fixedSize(
                    horizontal: false, vertical: true)
            }
        }.padding(m.sp16).frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).strokeBorder(colors.border))
    }

    private func notificationStatusTitle(_ status: DesktopNotificationStatus) -> String {
        switch status.authorization {
        case .notDetermined: "Not set up yet"
        case .denied: "Blocked in System Settings → Notifications"
        case .provisional: "Delivered quietly"
        case .authorized:
            switch status.alerts {
            case .enabled, .unknown: "Allowed"
            case .disabled: "Alerts are off in System Settings → Notifications"
            case .notSupported: "Alerts aren’t supported"
            }
        case .unknown: "Unknown; check System Settings → Notifications"
        }
    }

    @MainActor private func refreshNotificationStatus() async {
        guard isPresented, tab == .notifications, !requestingNotifications else { return }
        let request = UUID()
        let context = notificationStatusContext
        notificationStatusRequest = request
        readingNotificationStatus = true
        notificationStatusError = nil
        do {
            let status = try await PlatformIntegration.shared.notificationStatus()
            guard !Task.isCancelled, notificationStatusRequest == request, notificationStatusContext == context else {
                return
            }
            notificationStatus = status
            readingNotificationStatus = false
        } catch {
            guard !Task.isCancelled, notificationStatusRequest == request, notificationStatusContext == context else {
                return
            }
            notificationStatus = nil
            notificationStatusError = error.localizedDescription
            readingNotificationStatus = false
        }
    }

    private var accountPane: some View {
        VStack(alignment: .leading, spacing: m.sp24) {
            HStack(spacing: m.sp16) {
                AvatarView(
                    name: matrix.user?.name ?? "Slatrix", size: m.avatarLarge, matrix: matrix,
                    source: matrix.user?.avatarURL)
                VStack(alignment: .leading, spacing: m.sp4) {
                    Text(matrix.user?.name ?? "Not signed in").font(m.font(.title3, .semibold))
                    Text(matrix.isPreview ? "Preview" : matrix.user?.id ?? "")
                        .font(m.font(.subheadline)).foregroundStyle(colors.textSecondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("Edit profile", action: onEditProfile).buttonStyle(.secondary)
                    .disabled(matrix.isPreview || matrix.user == nil)
            }
            Divider().overlay(colors.border)
            VStack(alignment: .leading, spacing: m.sp12) {
                sectionTitle("Security")
                DeviceVerificationSettings(
                    service: matrix.verification, disabled: matrix.isPreview || matrix.user == nil,
                    onRecovery: onRecovery)
            }.padding(m.sp16).frame(maxWidth: .infinity, alignment: .leading).background(
                colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge)
            ).overlay(RoundedRectangle(cornerRadius: m.radiusLarge).strokeBorder(colors.border))
            Button(role: .destructive, action: onLogout) {
                Label(
                    matrix.isPreview ? "Leave preview" : "Sign out",
                    systemImage: "rectangle.portrait.and.arrow.right")
            }.buttonStyle(.secondary)
        }
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: m.sp24) {
            Toggle(
                isOn: Binding(
                    get: { openAtLogin },
                    set: { enabled in
                        loginToggleEdited = true
                        do {
                            try PlatformIntegration.shared.setOpenAtLogin(enabled)
                            openAtLogin = PlatformIntegration.shared.openAtLogin
                        } catch {
                            self.error = error.localizedDescription
                            openAtLogin = PlatformIntegration.shared.openAtLogin
                        }
                    })
            ) {
                sectionTitle("Open Slatrix at login")
            }.toggleStyle(.switch)
            Divider().overlay(colors.border)
            HStack(alignment: .top, spacing: m.sp16) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable()
                    .frame(width: m(Self.aboutIcon), height: m(Self.aboutIcon)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: m.sp4) {
                    sectionTitle("Slatrix")
                    Text("Version \(PlatformIntegration.shared.version)").foregroundStyle(colors.textSecondary)
                        .textSelection(.enabled)
                    Link("© 2026 Nuanu AI Lab", destination: URL(string: "https://nuanu.ai")!).buttonStyle(.textLink)
                        .padding(.top, m.sp8)
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/nuanu-ai/slatrix")!)
                        .buttonStyle(.textLink)
                }.font(m.font(.body))
            }.padding(m.sp16).frame(maxWidth: .infinity, alignment: .leading).background(
                colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge)
            ).overlay(RoundedRectangle(cornerRadius: m.radiusLarge).strokeBorder(colors.border))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(m.font(.body, .bold)).foregroundStyle(colors.textPrimary)
    }

    private func choiceTile<Preview: View>(
        label: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder preview: () -> Preview
    ) -> some View {
        PreferenceChoiceTile(
            label: label, selected: selected, miniatureHeight: Self.miniatureHeight, action: action, preview: preview())
    }

    private func changeNotifications(_ enabled: Bool) {
        if !enabled {
            appearance.notifications = false
            PlatformIntegration.shared.clearNotifications()
            return
        }
        let request = UUID()
        let session = matrix.notificationSessionID
        notificationPermissionRequest = request
        notificationStatusRequest = UUID()
        readingNotificationStatus = false
        requestingNotifications = true
        Task { @MainActor in
            guard isPresented, notificationPermissionRequest == request, matrix.notificationSessionID == session else {
                return
            }
            do {
                let granted = try await PlatformIntegration.shared.requestNotificationPermission()
                guard notificationPermissionRequest == request, matrix.notificationSessionID == session else { return }
                appearance.notifications = granted
                if !appearance.notifications {
                    error = "Notifications are off for Slatrix in System Settings → Notifications."
                }
            } catch {
                guard notificationPermissionRequest == request, matrix.notificationSessionID == session else { return }
                appearance.notifications = false
                self.error = error.localizedDescription
            }
            requestingNotifications = false
            await refreshNotificationStatus()
        }
    }
}

/// Lays out preference choice tiles in 3, 2, or 1 equal-width columns based on available width, never overflowing or
/// collapsing to zero columns in narrow windows.
private struct ChoiceGrid: Layout {
    struct Cache {
        var width: CGFloat = .nan
        var columns = 0
        var rowHeights: [CGFloat] = []
    }

    let minColumnWidth: CGFloat
    let spacing: CGFloat

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 3 }
        let fitting = Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down))
        return max(1, min(3, fitting))
    }

    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) -> (Int, CGFloat, [CGFloat]) {
        let columns = columnCount(for: width)
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let rows = (subviews.count + columns - 1) / columns
        if cache.width == width && cache.columns == columns && cache.rowHeights.count == rows {
            return (columns, columnWidth, cache.rowHeights)
        }
        var heights: [CGFloat] = []
        heights.reserveCapacity(rows)
        for row in 0..<rows {
            let start = row * columns
            let end = min(start + columns, subviews.count)
            let rowHeight =
                subviews[start..<end].map {
                    $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
                }.max() ?? 0
            heights.append(rowHeight)
        }
        cache = Cache(width: width, columns: columns, rowHeights: heights)
        return (columns, columnWidth, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? (3 * minColumnWidth + 2 * spacing)
        let (_, _, heights) = measure(width: width, subviews: subviews, cache: &cache)
        let totalHeight = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard !subviews.isEmpty else { return }
        let (columns, columnWidth, heights) = measure(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (row, rowHeight) in heights.enumerated() {
            let start = row * columns
            let end = min(start + columns, subviews.count)
            for column in 0..<(end - start) {
                let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
                subviews[start + column].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: columnWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }
}

/// A Preferences mode or theme choice card with hover feedback.
private struct PreferenceChoiceTile<Preview: View>: View {
    let label: String
    let selected: Bool
    let miniatureHeight: CGFloat
    let action: () -> Void
    let preview: Preview
    @State private var hovering = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Button(action: action) {
            VStack(alignment: .leading, spacing: m.sp8) {
                preview.frame(height: m(miniatureHeight)).clipShape(RoundedRectangle(cornerRadius: m.radius))
                    .padding(m.sp4)
                    .background(
                        hovering && !selected ? colors.hover : .clear,
                        in: RoundedRectangle(cornerRadius: m.radiusLarge)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: m.radiusLarge).stroke(
                            selected ? colors.accent : hovering ? colors.borderStrong : colors.border,
                            lineWidth: selected ? 2 : 1))
                HStack(spacing: m.sp4) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(
                        selected ? colors.accent : colors.textSecondary)
                    Text(label).foregroundStyle(colors.textBody)
                }.font(m.font(.subheadline, selected ? .semibold : .regular))
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.row).onHover { hovering = $0 }.accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A drawn thumbnail of the unified floating-sidebar window; its inner sizes are illustration proportions, scaled as a
/// whole.
private struct AppMiniature: View {
    @Environment(\.metrics) private var m
    let colors: AppColors
    var split = false

    var body: some View {
        let sidebarColors =
            split
            ? AppColors(dark: true, theme: colors.theme, highContrast: colors.highContrast)
            : colors
        let conversationColors =
            split
            ? AppColors(dark: false, theme: colors.theme, highContrast: colors.highContrast)
            : colors
        let side = sidebarColors.onSidebar
        let panelRadius = m(5)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: m.sp4) {
                HStack(spacing: m(3)) {
                    ForEach(0..<3) { _ in
                        Circle().fill(side.textSecondary.opacity(0.45)).frame(width: m(3.5), height: m(3.5))
                    }
                }.padding(.bottom, m.sp2)
                Capsule().fill(side.textSecondary.opacity(0.55)).frame(width: m(26), height: m(3.5))
                RoundedRectangle(cornerRadius: m(2)).fill(
                    sidebarColors.coloredSidebar ? side.selection : sidebarColors.accentFill
                ).frame(height: m(7))
                Capsule().fill(side.textSecondary.opacity(0.28)).frame(width: m(22), height: m(3))
                Capsule().fill(side.textSecondary.opacity(0.28)).frame(width: m(28), height: m(3))
                Spacer(minLength: 0)
            }
            .padding(m(6))
            .frame(width: m(44), alignment: .leading)
            .background { miniatureSidebarFill(sidebarColors) }
            .clipShape(RoundedRectangle(cornerRadius: panelRadius))
            .overlay(
                RoundedRectangle(cornerRadius: panelRadius).strokeBorder(
                    side.border, lineWidth: colors.highContrast ? 1 : 0.5)
            )
            .padding(.leading, m(3)).padding(.vertical, m(3))

            VStack(alignment: .leading, spacing: m.sp8) {
                HStack(spacing: m.sp4) {
                    Capsule().fill(conversationColors.textBody.opacity(0.5)).frame(width: m(28), height: m(4))
                    Spacer()
                    Capsule().fill(conversationColors.textSecondary.opacity(0.16)).frame(width: m(24), height: m(4))
                }
                ForEach(0..<2) { index in
                    HStack(alignment: .top, spacing: m.sp4) {
                        Circle().fill(avatarColor(index == 0 ? "Alex" : "Julia"))
                            .frame(width: m(9), height: m(9))
                        VStack(alignment: .leading, spacing: m.sp4) {
                            Capsule().fill(conversationColors.textBody.opacity(0.3)).frame(width: m(23), height: m(3))
                            Capsule().fill(conversationColors.textSecondary.opacity(0.18)).frame(height: m(3))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(m.sp8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(conversationColors.canvas)
        }
        .background(sidebarColors.canvas)
        .accessibilityHidden(true)
    }

    /// Deterministic preview fill for thumbnails so Light/Dark/System Glass tiles do not inherit the host window's
    /// live behind-window desktop vibrancy.
    @ViewBuilder private func miniatureSidebarFill(_ sidebarColors: AppColors) -> some View {
        if sidebarColors.translucentSidebar {
            LinearGradient(
                colors: [sidebarColors.raised, sidebarColors.overlay],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).overlay(sidebarColors.sidebar)
        } else {
            SidebarBackground(colors: sidebarColors)
        }
    }
}
