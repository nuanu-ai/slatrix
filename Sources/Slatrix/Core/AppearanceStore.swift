import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}
/// The window's neutrals, in light and dark, or, as Slack's themes do, a color for the window's frame around the
/// conversation. Every theme keeps the system accent.
enum ColorTheme: String, CaseIterable, Identifiable {
    case standard, slate, sand, contrast, aubergine, jade, lagoon, midnight, glass
    var id: String { rawValue }
    var name: String {
        switch self {
        case .contrast: "High Contrast"
        default: self == .standard ? "Default" : rawValue.capitalized
        }
    }
    /// The sidebar sits on the window's frame, and the conversation is a card on it.
    var framed: Bool { ![.standard, .slate, .sand, .contrast].contains(self) }
}
enum MessageDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
}

@MainActor final class AppearanceStore: ObservableObject {
    @Published var mode = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appearance.mode") ?? "dark") ?? .dark
    { didSet { save(mode.rawValue, "mode") } }
    @Published var theme =
        ColorTheme(rawValue: UserDefaults.standard.string(forKey: "appearance.theme") ?? "") ?? .standard
    { didSet { save(theme.rawValue, "theme") } }
    /// Slack's window gradient: a frame theme's frame fades into a neighboring hue.
    @Published var windowGradient = UserDefaults.standard.bool(forKey: "appearance.windowGradient") {
        didSet { UserDefaults.standard.set(windowGradient, forKey: "appearance.windowGradient") }
    }
    @Published var density =
        MessageDensity(rawValue: UserDefaults.standard.string(forKey: "appearance.density") ?? "comfortable")
        ?? .comfortable
    { didSet { save(density.rawValue, "density") } }
    /// Slack's zoom steps; ⌘= / ⌘- move between them and ⌘0 returns to 100%.
    static let zoomSteps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    @Published var zoom = AppearanceStore.validZoom(UserDefaults.standard.double(forKey: "appearance.zoom")) {
        didSet { UserDefaults.standard.set(zoom, forKey: "appearance.zoom") }
    }
    var canZoomIn: Bool { zoom < Self.zoomSteps.last! }
    var canZoomOut: Bool { zoom > Self.zoomSteps.first! }
    static func zoomedIn(_ zoom: Double) -> Double { zoomSteps.first { $0 > zoom } ?? zoom }
    static func zoomedOut(_ zoom: Double) -> Double { zoomSteps.last { $0 < zoom } ?? zoom }
    static func validZoom(_ value: Double) -> Double { zoomSteps.contains(value) ? value : 1 }
    @Published var showAvatars = UserDefaults.standard.object(forKey: "appearance.showAvatars") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAvatars, forKey: "appearance.showAvatars") }
    }
    @Published var notifications = UserDefaults.standard.object(forKey: "notifications.enabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(notifications, forKey: "notifications.enabled") }
    }
    @Published var notificationPreview = UserDefaults.standard.bool(forKey: "notifications.preview") {
        didSet { UserDefaults.standard.set(notificationPreview, forKey: "notifications.preview") }
    }
    @Published var systemIsDark = true
    var preferredColorScheme: ColorScheme? { mode == .system ? nil : mode == .dark ? .dark : .light }
    var isDark: Bool { mode == .dark || (mode == .system && systemIsDark) }
    /// The system accent in each theme, resolved once; picking another in System Settings redraws the window.
    private var accents: [Bool: NSColor] = [:]
    @Published private var accentChanges = 0
    private var accentObserver: NSObjectProtocol?

    init() {
        accentObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.accents = [:]
                self?.accentChanges += 1
            }
        }
    }

    func accent(dark: Bool) -> NSColor {
        if let accent = accents[dark] { return accent }
        let accent = AppColors.resolve(.controlAccentColor, dark: dark)
        accents[dark] = accent
        return accent
    }
    private func save(_ value: String, _ key: String) { UserDefaults.standard.set(value, forKey: "appearance.\(key)") }
}
