import Darwin
import Foundation

enum ScrollSpeedPreset: Int, CaseIterable {
    case gentle = 0
    case standard = 1
    case fast = 2

    var title: String {
        switch self {
        case .gentle: return "偏慢（精准）"
        case .standard: return "标准（推荐）"
        case .fast: return "偏快（长页面）"
        }
    }

    var basePixelsPerNotch: Double {
        switch self {
        case .gentle: return 36.0
        case .standard: return 52.0
        case .fast: return 74.0
        }
    }
}

final class AppSettings {
    static let shared = AppSettings()

    static let selfBundleID = "com.dockwing.app"

    // Only protect critical macOS system daemons (Finder/Dock/etc.) from ever being auto-quit
    static let hardProtectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.SystemUIServer",
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
        selfBundleID
    ]

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enableDockClickMinimize = "enableDockClickMinimize"
        static let enableLastWindowAutoQuit = "enableLastWindowAutoQuit"
        static let enableCmdWAutoQuit = "enableCmdWAutoQuit"
        static let enableDockHoverWindowPicker = "enableDockHoverWindowPicker"
        static let enableNotchMissionControl = "enableNotchMissionControl"
        static let enableSmoothScroll = "enableSmoothScroll"
        static let scrollSpeedPreset = "scrollSpeedPreset"
        static let enableModifierWheelZoom = "enableModifierWheelZoom"
        static let enableStageManagerRightClick = "enableStageManagerRightClick"
        static let enableMiddleDragScroll = "enableMiddleDragScroll"
    }

    var enableDockClickMinimize: Bool {
        didSet { defaults.set(enableDockClickMinimize, forKey: Keys.enableDockClickMinimize) }
    }

    var enableLastWindowAutoQuit: Bool {
        didSet { defaults.set(enableLastWindowAutoQuit, forKey: Keys.enableLastWindowAutoQuit) }
    }

    var enableCmdWAutoQuit: Bool {
        didSet { defaults.set(enableCmdWAutoQuit, forKey: Keys.enableCmdWAutoQuit) }
    }

    var enableDockHoverWindowPicker: Bool {
        didSet {
            defaults.set(enableDockHoverWindowPicker, forKey: Keys.enableDockHoverWindowPicker)
            NotificationCenter.default.post(name: .dockWingHoverSettingChanged, object: nil)
        }
    }

    var enableNotchMissionControl: Bool {
        didSet {
            defaults.set(enableNotchMissionControl, forKey: Keys.enableNotchMissionControl)
            NotificationCenter.default.post(name: .dockWingHoverSettingChanged, object: nil)
        }
    }

    var enableSmoothScroll: Bool {
        didSet { defaults.set(enableSmoothScroll, forKey: Keys.enableSmoothScroll) }
    }

    var scrollSpeedPreset: ScrollSpeedPreset {
        didSet { defaults.set(scrollSpeedPreset.rawValue, forKey: Keys.scrollSpeedPreset) }
    }

    var enableModifierWheelZoom: Bool {
        didSet { defaults.set(enableModifierWheelZoom, forKey: Keys.enableModifierWheelZoom) }
    }

    var enableStageManagerRightClick: Bool {
        didSet { defaults.set(enableStageManagerRightClick, forKey: Keys.enableStageManagerRightClick) }
    }

    var enableMiddleDragScroll: Bool {
        didSet { defaults.set(enableMiddleDragScroll, forKey: Keys.enableMiddleDragScroll) }
    }

    var launchAtLogin: Bool {
        DockManager.isLaunchAgentInstalled()
    }

    private init() {
        self.enableDockClickMinimize = defaults.object(forKey: Keys.enableDockClickMinimize) as? Bool ?? true
        self.enableLastWindowAutoQuit = defaults.object(forKey: Keys.enableLastWindowAutoQuit) as? Bool ?? true
        self.enableCmdWAutoQuit = defaults.object(forKey: Keys.enableCmdWAutoQuit) as? Bool ?? false
        self.enableDockHoverWindowPicker = defaults.object(forKey: Keys.enableDockHoverWindowPicker) as? Bool ?? true
        self.enableNotchMissionControl = defaults.object(forKey: Keys.enableNotchMissionControl) as? Bool ?? true
        self.enableSmoothScroll = defaults.object(forKey: Keys.enableSmoothScroll) as? Bool ?? true
        let rawSpeed = defaults.object(forKey: Keys.scrollSpeedPreset) as? Int ?? ScrollSpeedPreset.standard.rawValue
        self.scrollSpeedPreset = ScrollSpeedPreset(rawValue: rawSpeed) ?? .standard
        self.enableModifierWheelZoom = defaults.object(forKey: Keys.enableModifierWheelZoom) as? Bool ?? true
        self.enableStageManagerRightClick = defaults.object(forKey: Keys.enableStageManagerRightClick) as? Bool ?? true
        self.enableMiddleDragScroll = defaults.object(forKey: Keys.enableMiddleDragScroll) as? Bool ?? true
    }

    func isSystemProtected(_ bundleID: String) -> Bool {
        Self.hardProtectedBundleIDs.contains(bundleID)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        DockManager.setLaunchAtLogin(enabled)
    }

    static func memoryFootprintMB(pid: pid_t) -> Double {
        var rusage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return 0 }
        return Double(rusage.ri_phys_footprint) / (1024.0 * 1024.0)
    }
}

extension Notification.Name {
    static let dockWingEventTapStatusChanged = Notification.Name("DockWingEventTapStatusChanged")
    static let dockWingHoverSettingChanged = Notification.Name("DockWingHoverSettingChanged")
}
