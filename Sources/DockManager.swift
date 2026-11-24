import Foundation

enum DockManager {
    private static let launchAgentLabel = "com.dockwing.app"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    static var installedAppPath: String {
        let candidate = "/Applications/DockWing.app"
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return Bundle.main.bundlePath
    }

    static func isLaunchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static func setLaunchAtLogin(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let dir = launchAgentURL.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let execPath = "\(installedAppPath)/Contents/MacOS/DockWing"
            let plist: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive"
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: launchAgentURL)
            }
        } else {
            try? fm.removeItem(at: launchAgentURL)
        }
    }
}
