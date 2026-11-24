import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private enum PrivateWindowSPI {
    typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SLPSSetFrontProcessWithOptionsFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias SLPSPostEventRecordToFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void

    private static let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static let _axGetWindow: AXUIElementGetWindowFn? = {
        guard let h = appServices, let s = dlsym(h, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(s, to: AXUIElementGetWindowFn.self)
    }()

    private static let _getProcessForPID: GetProcessForPIDFn? = {
        guard let h = appServices, let s = dlsym(h, "GetProcessForPID") else { return nil }
        return unsafeBitCast(s, to: GetProcessForPIDFn.self)
    }()

    private static let _setFrontProcessWithOptions: SLPSSetFrontProcessWithOptionsFn? = {
        guard let h = skyLight, let s = dlsym(h, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(s, to: SLPSSetFrontProcessWithOptionsFn.self)
    }()

    private static let _postEventRecordTo: SLPSPostEventRecordToFn? = {
        guard let h = skyLight, let s = dlsym(h, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(s, to: SLPSPostEventRecordToFn.self)
    }()

    private static let _coreDockSendNotification: CoreDockSendNotificationFn? = {
        guard let h = appServices, let s = dlsym(h, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(s, to: CoreDockSendNotificationFn.self)
    }()

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let fn = _axGetWindow else { return nil }
        var wid: CGWindowID = 0
        guard fn(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    static func focusExactWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getPSN = _getProcessForPID,
              let setFront = _setFrontProcessWithOptions,
              let postEvent = _postEventRecordTo else {
            return false
        }

        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard getPSN(pid, &psn) == noErr else { return false }

        // kCPSUserGenerated = 0x200: tells WindowServer to bring this exact window to the very front
        let kCPSUserGenerated: UInt32 = 0x200
        _ = setFront(&psn, windowID, kCPSUserGenerated)

        // Make this exact CGWindowID the key window (handles Electron / Chromium / Bilibili / Chrome reliably)
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var widLE = windowID.littleEndian
        withUnsafeBytes(of: &widLE) { raw in
            for i in 0..<4 {
                bytes[0x3c + i] = raw[i]
            }
        }
        for i in 0x20..<0x30 {
            bytes[i] = 0xff
        }

        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { buf in
            postEvent(&psn, buf.baseAddress!)
        }

        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { buf in
            postEvent(&psn, buf.baseAddress!)
        }

        return true
    }

    static func triggerMissionControl() {
        if let send = _coreDockSendNotification {
            send("com.apple.expose.awake" as CFString, nil)
            return
        }
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

struct DockTileHit {
    let element: AXUIElement
    let title: String?
    let subrole: String?
    let url: URL?
    let bundleID: String?
    let frame: CGRect?
}

enum AXHelper {
    private static let stateLock = NSLock()
    private static var cachedDockPID: pid_t = 0
    private static var cachedDockElement: AXUIElement?
    private static var cachedOrientation: String = "bottom"
    private static var lastOrientationCheck: Date = .distantPast

    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func invalidateDockCache() {
        stateLock.lock()
        cachedDockPID = 0
        cachedDockElement = nil
        lastOrientationCheck = .distantPast
        stateLock.unlock()
    }

    static func dockAppElement() -> AXUIElement? {
        guard let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            invalidateDockCache()
            return nil
        }

        let pid = existing.processIdentifier
        stateLock.lock()
        defer { stateLock.unlock() }

        if pid != cachedDockPID || cachedDockElement == nil {
            cachedDockPID = pid
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.25)
            cachedDockElement = el
        }
        return cachedDockElement
    }

    static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let unwrapped = value else { return nil }
        return unwrapped as? T
    }

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute)
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        if let num: NSNumber = copyAttribute(element, attribute) {
            return num.boolValue
        }
        return nil
    }

    static func copyURL(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let unwrapped = value else { return nil }
        if let url = unwrapped as? URL {
            return url
        }
        if let str = unwrapped as? String {
            return URL(string: str)
        }
        return nil
    }

    static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        if AXValueGetValue(raw as! AXValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        if AXValueGetValue(raw as! AXValue, .cgSize, &size) {
            return size
        }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = copyPoint(element, kAXPositionAttribute),
              let size = copySize(element, kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// Convert a CGEvent / AX top-left global coordinate rect to AppKit bottom-left coordinate rect.
    static func cgRectToAppKit(_ rect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        guard primaryHeight > 0 else { return rect }
        let appKitY = primaryHeight - rect.origin.y - rect.size.height
        return CGRect(x: rect.origin.x, y: appKitY, width: rect.size.width, height: rect.size.height)
    }

    /// Find the Dock tile under a given CGEvent global screen point (top-left origin).
    static func dockTileAt(cgPoint: CGPoint) -> DockTileHit? {
        guard let dockEl = dockAppElement() else { return nil }

        var hitRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(dockEl, Float(cgPoint.x), Float(cgPoint.y), &hitRef)
        guard err == .success, let hit = hitRef else { return nil }

        // Walk up if we hit a child inside an AXDockItem
        var current = hit
        for _ in 0..<4 {
            let role = copyString(current, kAXRoleAttribute)
            if role == "AXDockItem" {
                break
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                current = (parent as! AXUIElement)
            } else {
                break
            }
        }

        guard copyString(current, kAXRoleAttribute) == "AXDockItem" else { return nil }

        let title = copyString(current, kAXTitleAttribute)
        let subrole = copyString(current, kAXSubroleAttribute)
        let url = copyURL(current, kAXURLAttribute)
        let frame = frame(of: current)

        var bundleID: String? = nil
        if let appURL = url {
            if let bid = Bundle(url: appURL)?.bundleIdentifier {
                bundleID = bid
            } else if let match = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
            }) {
                bundleID = match.bundleIdentifier
            }
        }
        if bundleID == nil, let title = title {
            if let match = NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular && (
                    $0.localizedName == title ||
                    $0.localizedName?.caseInsensitiveCompare(title) == .orderedSame
                )
            }) {
                bundleID = match.bundleIdentifier
            }
        }

        return DockTileHit(
            element: current,
            title: title,
            subrole: subrole,
            url: url,
            bundleID: bundleID,
            frame: frame
        )
    }

    private static let ignoredAuxiliarySubroles: Set<String> = [
        "AXSheet", "AXSystemDialog", "AXFloatingWindow", "AXPopover", "AXUnknown"
    ]

    struct AppWindowSummary {
        let userWindows: [AXUIElement]
        let visibleNonMinimizedWindows: [AXUIElement]
        let hasBlockingSheetOrSystemDialog: Bool
    }

    /// Inspect all windows of a given PID consistently for minimize & last-window auto-quit decisions.
    static func inspectWindows(pid: pid_t) -> AppWindowSummary {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)

        guard let windows: [AXUIElement] = copyAttribute(appEl, kAXWindowsAttribute) else {
            return AppWindowSummary(
                userWindows: [],
                visibleNonMinimizedWindows: [],
                hasBlockingSheetOrSystemDialog: false
            )
        }

        var userWindows: [AXUIElement] = []
        var visibleNonMinimized: [AXUIElement] = []
        var hasBlockingSheet = false

        for win in windows {
            let role = copyString(win, kAXRoleAttribute) ?? ""
            let subrole = copyString(win, kAXSubroleAttribute) ?? ""

            // Only true modal sheets/system alerts (e.g. "Save changes?") block auto-quit.
            // Standalone AXDialog windows (e.g. Preferences/Settings) are treated as normal user windows.
            if subrole == "AXSheet" || subrole == "AXSystemDialog" {
                hasBlockingSheet = true
                continue
            }

            if let sheets: [AXUIElement] = copyAttribute(win, "AXSheets"), !sheets.isEmpty {
                hasBlockingSheet = true
            }

            guard role == (kAXWindowRole as String) else { continue }
            guard !ignoredAuxiliarySubroles.contains(subrole) else { continue }

            // Ignore tiny invisible helper windows (common in Electron / status bar apps)
            if let size = copySize(win, kAXSizeAttribute), (size.width < 100 || size.height < 70) {
                continue
            }

            userWindows.append(win)

            let isMinimized = copyBool(win, kAXMinimizedAttribute) ?? false
            if !isMinimized {
                visibleNonMinimized.append(win)
            }
        }

        return AppWindowSummary(
            userWindows: userWindows,
            visibleNonMinimizedWindows: visibleNonMinimized,
            hasBlockingSheetOrSystemDialog: hasBlockingSheet
        )
    }

    /// Minimize all visible windows of an app with safe fallbacks for full-screen or non-standard windows.
    static func minimizeApp(_ app: NSRunningApplication) {
        let summary = inspectWindows(pid: app.processIdentifier)
        guard !summary.visibleNonMinimizedWindows.isEmpty else { return }

        var anyFullScreen = false
        var anyMinimized = false

        for win in summary.visibleNonMinimizedWindows {
            if copyBool(win, "AXFullScreen") == true {
                anyFullScreen = true
                continue
            }

            let err = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            if err == .success {
                anyMinimized = true
            } else {
                // Fallback 1: press the minimize button directly
                var minBtnRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXMinimizeButtonAttribute as CFString, &minBtnRef) == .success,
                   let minBtn = minBtnRef, CFGetTypeID(minBtn) == AXUIElementGetTypeID() {
                    if AXUIElementPerformAction(minBtn as! AXUIElement, kAXPressAction as CFString) == .success {
                        anyMinimized = true
                    }
                }
            }
        }

        // Fallback 2: if full-screen or the app rejected AX minimization, hide the app cleanly
        if !anyMinimized || anyFullScreen {
            DispatchQueue.main.async {
                app.hide()
            }
        }
    }

    struct WindowEntry {
        let element: AXUIElement
        let title: String
        let isMinimized: Bool
        let isFocused: Bool
    }

    /// List all user windows (including minimized ones) of a running app for the lightweight hover picker.
    static func listStandardWindows(for app: NSRunningApplication) -> [WindowEntry] {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.2)

        guard let windows: [AXUIElement] = copyAttribute(appEl, kAXWindowsAttribute) else {
            return []
        }

        var focusedWin: AXUIElement? = nil
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let raw = focusedRef, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            focusedWin = (raw as! AXUIElement)
        }

        let fallbackName = app.localizedName ?? "未命名窗口"
        var entries: [WindowEntry] = []

        for win in windows {
            let role = copyString(win, kAXRoleAttribute) ?? ""
            let subrole = copyString(win, kAXSubroleAttribute) ?? ""
            guard role == (kAXWindowRole as String) else { continue }
            guard !ignoredAuxiliarySubroles.contains(subrole) else { continue }

            if let size = copySize(win, kAXSizeAttribute), (size.width < 100 || size.height < 70) {
                continue
            }

            let rawTitle = (copyString(win, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? fallbackName : rawTitle
            let isMinimized = copyBool(win, kAXMinimizedAttribute) ?? false
            let isFocused = focusedWin.map { CFEqual($0, win) } ?? false

            entries.append(WindowEntry(
                element: win,
                title: title,
                isMinimized: isMinimized,
                isFocused: isFocused && app.isActive && !isMinimized
            ))
        }

        return entries
    }

    /// Reliably bring one specific window of an app to the very front (handles Electron/Chromium/Bilibili,
    /// WeChat minimized windows, covered windows, and sibling window switching without .activateAllWindows).
    static func focusWindow(_ window: AXUIElement, of app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)

        let wasMinimized = (copyBool(window, kAXMinimizedAttribute) == true)
        if wasMinimized {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        if app.isHidden {
            _ = AXUIElementSetAttributeValue(appEl, kAXHiddenAttribute as CFString, kCFBooleanFalse)
            DispatchQueue.main.async { app.unhide() }
        }

        let exactWID = PrivateWindowSPI.windowID(for: window)

        func raiseOnce() {
            if let wid = exactWID {
                _ = PrivateWindowSPI.focusExactWindow(pid: pid, windowID: wid)
            }
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, window)
            _ = AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, window)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        raiseOnce()

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            DispatchQueue.main.async {
                app.activate(options: [])
            }
        }

        let delaysMs = wasMinimized ? [60, 220] : [50]
        for ms in delaysMs {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(ms)) {
                raiseOnce()
            }
        }
    }

    /// Trigger macOS Mission Control / desktop switcher mode (same native behavior as Control + Up).
    static func triggerMissionControl() {
        PrivateWindowSPI.triggerMissionControl()
    }

    /// Expose CGWindowID lookup for matching Stage Manager AXWindowsIDs to concrete AXUIElement windows.
    static func windowID(for element: AXUIElement) -> CGWindowID? {
        PrivateWindowSPI.windowID(for: element)
    }

    /// Gracefully close one specific window via its native AXCloseButton.
    static func closeWindow(_ window: AXUIElement) -> Bool {
        var btnRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &btnRef) == .success,
              let raw = btnRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return false
        }
        return AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Safely check whether the UI element at a global CGEvent point is an external app's window close button.
    /// Never calls AXUIElementCopyElementAtPosition on systemWide or our own PID, preventing AppKit background-thread crashes.
    static func closeButtonInfo(at cgPoint: CGPoint) -> (pid: pid_t, isUserWindow: Bool)? {
        let myPID = getpid()

        // 1. Thread-safe C WindowServer lookup: find the topmost on-screen normal window under cgPoint
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var targetPID: pid_t = 0
        var targetBounds: CGRect = .zero

        for info in windowList {
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue } // Normal app windows only (automatically skips Dock/menu/floating overlays)

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 100, bounds.height >= 70,
                  bounds.contains(cgPoint) else {
                continue
            }

            let ownerPID = (info[kCGWindowOwnerPID as String] as? pid_t) ?? 0
            if ownerPID == myPID || ownerPID <= 0 {
                return nil
            }
            targetPID = ownerPID
            targetBounds = bounds
            break
        }

        guard targetPID > 0 else { return nil }

        // 2. Fast geometric filter: traffic-light red close button is always near the top titlebar of the window
        let offsetFromTop = cgPoint.y - targetBounds.minY
        guard offsetFromTop >= -4 && offsetFromTop <= 56 else {
            return nil
        }

        // 3. Skip Finder/system processes before touching AX IPC
        guard let runningApp = NSRunningApplication(processIdentifier: targetPID),
              runningApp.activationPolicy == .regular,
              let bid = runningApp.bundleIdentifier,
              !AppSettings.shared.isSystemProtected(bid) else {
            return nil
        }

        // 4. Pure cross-process Mach IPC to the external app (guaranteed never to re-enter our own AppKit!)
        let appEl = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(appEl, 0.2)

        var hitRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(appEl, Float(cgPoint.x), Float(cgPoint.y), &hitRef)
        guard err == .success, let hit = hitRef else { return nil }

        var closeBtn: AXUIElement? = nil
        var current: AXUIElement = hit
        for _ in 0..<3 {
            if copyString(current, kAXSubroleAttribute) == (kAXCloseButtonSubrole as String) {
                closeBtn = current
                break
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                current = (parent as! AXUIElement)
            } else {
                break
            }
        }

        guard let button = closeBtn else { return nil }

        var isUserWindow = true
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(button, kAXWindowAttribute as CFString, &winRef) == .success,
           let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() {
            let subrole = copyString(win as! AXUIElement, kAXSubroleAttribute) ?? ""
            if ignoredAuxiliarySubroles.contains(subrole) {
                isUserWindow = false
            }
        }

        return (targetPID, isUserWindow)
    }

    /// Fast O(1), thread-safe geometric check using CoreGraphics display bounds (safe from any thread).
    static func isPointInDockEdgeBand(_ cgPoint: CGPoint) -> Bool {
        let orientation = dockOrientation()

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return false
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return false
        }

        let band: CGFloat = 140.0
        for i in 0..<Int(displayCount) {
            let cgFrame = CGDisplayBounds(displays[i])
            guard cgFrame.contains(cgPoint) else { continue }
            switch orientation {
            case "left":
                return cgPoint.x <= cgFrame.minX + band
            case "right":
                return cgPoint.x >= cgFrame.maxX - band
            default: // bottom
                return cgPoint.y >= cgFrame.maxY - band
            }
        }
        return false
    }

    static func dockOrientation() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        if Date().timeIntervalSince(lastOrientationCheck) > 10 {
            let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
            cachedOrientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"
            lastOrientationCheck = Date()
        }
        return cachedOrientation
    }
}
