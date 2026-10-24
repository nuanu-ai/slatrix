import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}
enum SidebarPalette: String, CaseIterable, Identifiable {
    case slate, aubergine, ocean, forest
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}
enum MessageDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
}

@MainActor final class AppearanceStore: ObservableObject {
    @Published var mode = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appearance.mode") ?? "dark") ?? .dark
    { didSet { save(mode.rawValue, "mode") } }
    @Published var palette =
        SidebarPalette(rawValue: UserDefaults.standard.string(forKey: "appearance.palette") ?? "slate") ?? .slate
    { didSet { save(palette.rawValue, "palette") } }
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
    private func save(_ value: String, _ key: String) { UserDefaults.standard.set(value, forKey: "appearance.\(key)") }
}
