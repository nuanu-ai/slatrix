import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

/// The window's neutrals and its floating sidebar surface, in light and dark. Every theme keeps the system accent.
enum ColorTheme: String, CaseIterable, Identifiable {
    case glass, neutral, sand, aubergine, jade, ocean

    enum Group: String, CaseIterable, Identifiable {
        case neutral, colored
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var themes: [ColorTheme] {
            switch self {
            case .neutral: [.glass, .neutral, .sand]
            case .colored: [.aubergine, .jade, .ocean]
            }
        }
    }

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    /// A rich colored floating sidebar island with light text and a built-in vertical gradient.
    var isColored: Bool {
        switch self {
        case .aubergine, .jade, .ocean: true
        case .glass, .neutral, .sand: false
        }
    }
    /// Translucent macOS sidebar material letting the desktop show through under a tint.
    var isTranslucent: Bool { self == .glass }

    /// Decodes persisted theme values, migrating removed legacy themes cleanly onto the 6 curated themes.
    static func migrated(_ rawValue: String) -> (theme: ColorTheme, migratedContrast: Bool)? {
        switch rawValue {
        case "standard", "slate": (.neutral, false)
        case "lagoon", "midnight": (.ocean, false)
        case "contrast": (.neutral, true)
        default: ColorTheme(rawValue: rawValue).map { ($0, false) }
        }
    }
}

enum MessageDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
}

@MainActor final class AppearanceStore: ObservableObject {
    private let defaults: UserDefaults

    @Published var mode: AppTheme {
        didSet { save(mode.rawValue, "mode") }
    }
    @Published var theme: ColorTheme {
        didSet { save(theme.rawValue, "theme") }
    }
    /// Repeating doodle texture behind messages; works independently on every theme.
    @Published var chatWallpaper: Bool {
        didSet { defaults.set(chatWallpaper, forKey: "appearance.chatWallpaper") }
    }
    /// High-contrast surfaces, text and borders; works independently on every theme.
    @Published var increaseContrast: Bool {
        didSet { defaults.set(increaseContrast, forKey: "appearance.increaseContrast") }
    }
    /// Per-workspace theme overrides keyed by Matrix space ID.
    @Published var workspaceThemes: [String: ColorTheme] {
        didSet { saveWorkspaceThemes() }
    }
    /// Currently open Matrix space ID, kept in sync by `RootView` so every view resolves the active workspace's theme.
    @Published var activeWorkspaceID: String?
    @Published var density: MessageDensity {
        didSet { save(density.rawValue, "density") }
    }
    /// Slack's zoom steps; ⌘= / ⌘- move between them and ⌘0 returns to 100%.
    static let zoomSteps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    @Published var zoom: Double {
        didSet { defaults.set(zoom, forKey: "appearance.zoom") }
    }
    var canZoomIn: Bool { zoom < Self.zoomSteps.last! }
    var canZoomOut: Bool { zoom > Self.zoomSteps.first! }
    static func zoomedIn(_ zoom: Double) -> Double { zoomSteps.first { $0 > zoom } ?? zoom }
    static func zoomedOut(_ zoom: Double) -> Double { zoomSteps.last { $0 < zoom } ?? zoom }
    static func validZoom(_ value: Double) -> Double { zoomSteps.contains(value) ? value : 1 }
    @Published var showAvatars: Bool {
        didSet { defaults.set(showAvatars, forKey: "appearance.showAvatars") }
    }
    @Published var notifications: Bool {
        didSet { defaults.set(notifications, forKey: "notifications.enabled") }
    }
    @Published var notificationPreview: Bool {
        didSet { defaults.set(notificationPreview, forKey: "notifications.preview") }
    }
    @Published var systemIsDark: Bool
    @Published var systemIncreaseContrast: Bool

    private static func currentSystemIsDark(defaults: UserDefaults) -> Bool {
        if let appearance = NSApp?.effectiveAppearance {
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return defaults.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
    var preferredColorScheme: ColorScheme? { mode == .system ? nil : mode == .dark ? .dark : .light }
    var isDark: Bool { mode == .dark || (mode == .system && systemIsDark) }
    var effectiveIncreaseContrast: Bool { increaseContrast || systemIncreaseContrast }
    var activeTheme: ColorTheme { effectiveTheme(for: activeWorkspaceID) }

    func effectiveTheme(for workspaceID: String?) -> ColorTheme {
        workspaceID.flatMap { workspaceThemes[$0] } ?? theme
    }

    func setTheme(_ theme: ColorTheme, for workspaceID: String) {
        workspaceThemes[workspaceID] = theme
    }

    func clearTheme(for workspaceID: String) {
        workspaceThemes.removeValue(forKey: workspaceID)
    }

    /// The system accent in each theme, resolved once; picking another in System Settings redraws the window.
    private var accents: [Bool: NSColor] = [:]
    @Published private var accentChanges = 0
    nonisolated(unsafe) private var accentObserver: NSObjectProtocol?
    nonisolated(unsafe) private var accessibilityObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppTheme(rawValue: defaults.string(forKey: "appearance.mode") ?? "system") ?? .system

        var migratedContrast = false
        var migratedGlobalTheme: ColorTheme?
        if let rawTheme = defaults.string(forKey: "appearance.theme"),
            let decoded = ColorTheme.migrated(rawTheme)
        {
            theme = decoded.theme
            if decoded.migratedContrast { migratedContrast = true }
            if decoded.theme.rawValue != rawTheme { migratedGlobalTheme = decoded.theme }
        } else {
            theme = .glass
        }

        var decodedWorkspaceThemes: [String: ColorTheme] = [:]
        var migratedWorkspaceThemes = false
        if let rawMap = defaults.dictionary(forKey: "appearance.workspaceThemes") {
            for (workspaceID, rawAny) in rawMap {
                if let rawValue = rawAny as? String, let decoded = ColorTheme.migrated(rawValue) {
                    decodedWorkspaceThemes[workspaceID] = decoded.theme
                    if decoded.migratedContrast { migratedContrast = true }
                    if decoded.theme.rawValue != rawValue { migratedWorkspaceThemes = true }
                } else {
                    migratedWorkspaceThemes = true
                }
            }
        }
        workspaceThemes = decodedWorkspaceThemes

        chatWallpaper = defaults.object(forKey: "appearance.chatWallpaper") as? Bool ?? true
        // Persist migrated Increase contrast before rewriting legacy "contrast" keys so an interrupted launch can retry.
        if let explicitContrast = defaults.object(forKey: "appearance.increaseContrast") as? Bool {
            increaseContrast = explicitContrast
        } else if migratedContrast {
            increaseContrast = true
            defaults.set(true, forKey: "appearance.increaseContrast")
        } else {
            increaseContrast = false
        }

        if let migratedGlobalTheme {
            defaults.set(migratedGlobalTheme.rawValue, forKey: "appearance.theme")
        }

        density =
            MessageDensity(rawValue: defaults.string(forKey: "appearance.density") ?? "comfortable") ?? .comfortable
        zoom = Self.validZoom(defaults.double(forKey: "appearance.zoom"))
        showAvatars = defaults.object(forKey: "appearance.showAvatars") as? Bool ?? true
        notifications = defaults.object(forKey: "notifications.enabled") as? Bool ?? false
        notificationPreview = defaults.bool(forKey: "notifications.preview")
        systemIsDark = Self.currentSystemIsDark(defaults: defaults)
        systemIncreaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        if migratedWorkspaceThemes { saveWorkspaceThemes() }

        accentObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.accents = [:]
                self?.accentChanges += 1
            }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemIncreaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            }
        }
    }

    deinit {
        if let accentObserver { NotificationCenter.default.removeObserver(accentObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    func accent(dark: Bool) -> NSColor {
        if let accent = accents[dark] { return accent }
        let accent = AppColors.resolve(.controlAccentColor, dark: dark)
        accents[dark] = accent
        return accent
    }

    private func save(_ value: String, _ key: String) { defaults.set(value, forKey: "appearance.\(key)") }

    private func saveWorkspaceThemes() {
        if workspaceThemes.isEmpty {
            defaults.removeObject(forKey: "appearance.workspaceThemes")
        } else {
            defaults.set(workspaceThemes.mapValues(\.rawValue), forKey: "appearance.workspaceThemes")
        }
    }
}
