import Darwin
import Foundation

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

    var launchAtLogin: Bool {
        DockManager.isLaunchAgentInstalled()
    }

    private init() {
        self.enableDockClickMinimize = defaults.object(forKey: Keys.enableDockClickMinimize) as? Bool ?? true
        self.enableLastWindowAutoQuit = defaults.object(forKey: Keys.enableLastWindowAutoQuit) as? Bool ?? true
        self.enableCmdWAutoQuit = defaults.object(forKey: Keys.enableCmdWAutoQuit) as? Bool ?? false
        self.enableDockHoverWindowPicker = defaults.object(forKey: Keys.enableDockHoverWindowPicker) as? Bool ?? true
        self.enableNotchMissionControl = defaults.object(forKey: Keys.enableNotchMissionControl) as? Bool ?? true
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
