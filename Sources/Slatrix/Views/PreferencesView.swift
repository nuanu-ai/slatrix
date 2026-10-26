import AppKit
import SwiftUI

struct PreferencesView: View {
    private static let size = CGSize(width: 848, height: 600)
    private static let headerHeight: CGFloat = 64
    private static let navWidth: CGFloat = 188
    private static let pickerWidth: CGFloat = 280
    private static let miniatureHeight: CGFloat = 72
    @Environment(\.metrics) private var m
    @EnvironmentObject var appearance: AppearanceStore
    let matrix: MatrixService
    var onClose: () -> Void
    var onLogout: () -> Void
    var onRecovery: () -> Void
    @State private var tab = PreferenceTab.appearance
    @State private var profileName = ""
    @State private var saving = false
    @State private var requestingNotifications = false
    @State private var notificationStatus: DesktopNotificationStatus?
    @State private var notificationStatusError: String?
    @State private var readingNotificationStatus = false
    @State private var notificationStatusRequest = UUID()
    @State private var notificationPermissionRequest = UUID()
    @State private var isPresented = false
    @State private var openAtLogin = false
    @State private var error: String?
    @State private var savedProfile = false
    private var colors: AppColors { appearance.colors }

    private enum PreferenceTab: String, CaseIterable, Identifiable, Hashable {
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
        let tab: PreferenceTab
        let session: UUID
    }
    private var notificationStatusContext: NotificationStatusContext {
        NotificationStatusContext(tab: tab, session: matrix.notificationSessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preferences").font(m.font(.title, .bold))
                Spacer()
                IconButton(symbol: "xmark", label: "Close", role: .body, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, m.sp24).frame(height: m(Self.headerHeight))
            Divider().overlay(colors.border)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: m.sp4) {
                    ForEach(PreferenceTab.allCases) { item in
                        Button {
                            tab = item
                            error = nil
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .font(m.font(.body, tab == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, m.sp12).frame(
                                    height: m.control
                                )
                                .foregroundStyle(tab == item ? colors.textPrimary : colors.textSecondary)
                                .background(
                                    tab == item ? colors.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: m.radius))
                        }.buttonStyle(.row).accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                    Spacer()
                }.padding(m.sp12).frame(width: m(Self.navWidth)).background(colors.raised)
                Divider().overlay(colors.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: m.sp24) {
                        Text(tab.title).font(m.font(.header, .bold)).foregroundStyle(colors.textPrimary)
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
                    }.padding(m.sp32).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.sheetSize(width: Self.size.width, height: Self.size.height).background(colors.canvas).foregroundStyle(
            colors.textBody
        )
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear {
            isPresented = true
            profileName = matrix.user?.name ?? ""
            openAtLogin = PlatformIntegration.shared.openAtLogin
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
        VStack(alignment: .leading, spacing: m.sp24) {
            VStack(alignment: .leading, spacing: m.sp12) {
                sectionTitle("Color mode")
                HStack(spacing: m.sp12) {
                    ForEach([AppTheme.dark, .light, .system]) { mode in
                        choiceTile(label: mode.name, selected: appearance.mode == mode) {
                            appearance.mode = mode
                        } preview: {
                            AppMiniature(
                                colors: AppColors(
                                    dark: mode == .dark || (mode == .system && appearance.systemIsDark),
                                    palette: appearance.palette), split: mode == .system)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: m.sp12) {
                sectionTitle("Sidebar theme")
                HStack(spacing: m.sp12) {
                    ForEach(SidebarPalette.allCases) { palette in
                        choiceTile(label: palette.name, selected: appearance.palette == palette) {
                            appearance.palette = palette
                        } preview: {
                            AppMiniature(colors: AppColors(dark: appearance.isDark, palette: palette))
                        }
                    }
                }
            }
            Divider().overlay(colors.border)
            VStack(alignment: .leading, spacing: m.sp12) {
                sectionTitle("Message density")
                Picker("Message density", selection: $appearance.density) {
                    Text("Comfortable").tag(MessageDensity.comfortable)
                    Text("Compact").tag(MessageDensity.compact)
                }.pickerStyle(.segmented).labelsHidden().frame(width: m(Self.pickerWidth))
            }
            Toggle("Show profile photos in conversations", isOn: $appearance.showAvatars).toggleStyle(.switch).font(
                m.font(.secondary))
        }
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
                }.font(m.font(.meta))
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
                    m.font(.secondary, .semibold))
                Spacer()
                if readingNotificationStatus {
                    DelayedProgress().accessibilityLabel("Checking macOS notification settings")
                }
                Button("Refresh") { Task { await refreshNotificationStatus() } }.buttonStyle(.textLink)
                    .disabled(readingNotificationStatus || requestingNotifications)
            }
            if let notificationStatus {
                Text(notificationStatusTitle(notificationStatus)).font(m.font(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notificationStatusError {
                Text(notificationStatusError).font(m.font(.meta)).foregroundStyle(colors.warning).fixedSize(
                    horizontal: false, vertical: true)
            }
        }.padding(m.sp16).frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
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
                    Text(matrix.user?.name ?? "Not signed in").font(m.font(.title, .semibold))
                    Text(matrix.isPreview ? "Preview" : matrix.user?.id ?? "")
                        .font(m.font(.meta)).foregroundStyle(colors.textSecondary).textSelection(.enabled)
                }
            }
            Divider().overlay(colors.border)
            VStack(alignment: .leading, spacing: m.sp8) {
                sectionTitle("Display name")
                HStack(spacing: m.sp12) {
                    TextField("Your name", text: $profileName).textFieldStyle(.field).onChange(of: profileName) {
                        _, _ in savedProfile = false
                    }
                    Button(savedProfile ? "Saved" : saving ? "Saving…" : "Save") { saveProfile() }.disabled(
                        saving || matrix.isPreview || matrix.user == nil
                            || profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || profileName == matrix.user?.name)
                }
            }
            VStack(alignment: .leading, spacing: m.sp12) {
                sectionTitle("Security")
                DeviceVerificationSettings(
                    service: matrix.verification, disabled: matrix.isPreview || matrix.user == nil,
                    onRecovery: onRecovery)
            }.padding(m.sp16).frame(maxWidth: .infinity, alignment: .leading).background(
                colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
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
            VStack(alignment: .leading, spacing: m.sp12) {
                sectionTitle("About Slatrix")
                detailRow("Version", value: PlatformIntegration.shared.version)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(colors.textSecondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }.font(m.font(.secondary))
    }

    private func choiceTile<Preview: View>(
        label: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder preview: () -> Preview
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: m.sp8) {
                preview().frame(height: m(Self.miniatureHeight)).clipShape(RoundedRectangle(cornerRadius: m.radius))
                    .padding(m.sp4).overlay(
                        RoundedRectangle(cornerRadius: m.radiusLarge).stroke(
                            selected ? colors.accent : colors.border, lineWidth: selected ? 2 : 1))
                HStack(spacing: m.sp4) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(
                        selected ? colors.accent : colors.textSecondary)
                    Text(label).foregroundStyle(colors.textBody)
                }.font(m.font(.meta, selected ? .semibold : .regular))
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.row).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
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

    private func saveProfile() {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await matrix.setProfile(name: name)
                profileName = name
                savedProfile = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// A drawn thumbnail of the app; its inner sizes are illustration proportions, scaled as a whole.
private struct AppMiniature: View {
    @Environment(\.metrics) private var m
    let colors: AppColors
    var split = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: m.sp4) {
                ForEach(0..<3) { _ in Circle().fill(colors.textSecondary.opacity(0.45)).frame(width: m(4), height: m(4))
                }
                Spacer()
                Capsule().fill(colors.textSecondary.opacity(0.13)).frame(width: m(42), height: m(5))
                Spacer()
            }.padding(.horizontal, m.sp8).frame(height: m(15)).background(colors.frame)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: m.sp4) {
                    Capsule().fill(colors.textSecondary.opacity(0.55)).frame(width: m(29), height: m(4))
                    RoundedRectangle(cornerRadius: m(2)).fill(colors.selection).frame(height: m(8))
                    Capsule().fill(colors.textSecondary.opacity(0.25)).frame(width: m(25), height: m(3))
                    Capsule().fill(colors.textSecondary.opacity(0.25)).frame(width: m(31), height: m(3))
                    Spacer(minLength: 0)
                }.padding(m.sp8).frame(width: m(47)).background(colors.sidebar)
                VStack(alignment: .leading, spacing: m.sp8) {
                    Capsule().fill(colors.textBody.opacity(0.5)).frame(width: m(29), height: m(4))
                    ForEach(0..<2) { index in
                        HStack(alignment: .top, spacing: m.sp4) {
                            RoundedRectangle(cornerRadius: m(2)).fill(
                                avatarColor(index == 0 ? "Alex" : "Julia")
                            ).frame(width: m(9), height: m(9))
                            VStack(alignment: .leading, spacing: m.sp4) {
                                Capsule().fill(colors.textBody.opacity(0.3)).frame(width: m(23), height: m(3))
                                Capsule().fill(colors.textSecondary.opacity(0.17)).frame(height: m(3))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(m.sp8).frame(maxWidth: .infinity).background(
                    split ? AppColors(dark: false, palette: colors.palette).raised : colors.canvas)
            }
        }.accessibilityHidden(true)
    }
}
