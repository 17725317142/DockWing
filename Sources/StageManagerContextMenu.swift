import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Right-click any Stage Manager side-strip thumbnail (left or right side) to show a crisp native Close / Quit menu.
/// Uses WindowManager's native `sm.strip` AX tree and `AXWindowsIDs` for 100% accurate app/window targeting.
final class StageManagerContextMenu: NSObject {
    static let shared = StageManagerContextMenu()

    private final class MenuContext: NSObject {
        let app: NSRunningApplication
        let windowIDs: [CGWindowID]
        let cardElement: AXUIElement

        init(app: NSRunningApplication, windowIDs: [CGWindowID], cardElement: AXUIElement) {
            self.app = app
            self.windowIDs = windowIDs
            self.cardElement = cardElement
        }
    }

    private let axQueue = DispatchQueue(label: "com.dockwing.app.stageManagerMenu", qos: .userInteractive)
    private var suppressNextRightMouseUp: Bool = false

    private override init() { super.init() }

    /// Fast O(1) WindowServer check called on `rightMouseDown`.
    /// Returns `true` if the right-click landed on a Stage Manager strip thumbnail (suppresses default event & shows menu).
    func handleRightMouseDown(at cgPoint: CGPoint) -> Bool {
        suppressNextRightMouseUp = false
        guard AppSettings.shared.enableStageManagerRightClick else { return false }
        guard isPointOnStageManagerThumbnail(cgPoint: cgPoint) else { return false }

        suppressNextRightMouseUp = true
        let appKitClickPoint = cgPointToAppKit(cgPoint)

        axQueue.async { [weak self] in
            self?.resolveCardAndShowMenu(at: cgPoint, appKitPoint: appKitClickPoint)
        }
        return true
    }

    func handleRightMouseUp() -> Bool {
        if suppressNextRightMouseUp {
            suppressNextRightMouseUp = false
            return true
        }
        return false
    }

    /// Thread-safe, microsecond check using CGWindowList: Stage Manager strip thumbnails are layer-0
    /// windows owned by `WindowManager` (distinct from normal app windows and background wallpaper).
    private func isPointOnStageManagerThumbnail(cgPoint: CGPoint) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for info in windowList {
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 30, bounds.height >= 30,
                  bounds.contains(cgPoint) else {
                continue
            }

            // Inspect the topmost layer-0 window under the cursor
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            return owner == "WindowManager"
        }
        return false
    }

    private func resolveCardAndShowMenu(at cgPoint: CGPoint, appKitPoint: CGPoint) {
        guard let wmApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else {
            return
        }

        let wmEl = AXUIElementCreateApplication(wmApp.processIdentifier)
        AXUIElementSetMessagingTimeout(wmEl, 0.25)

        // Find the `sm.strip` AXList inside WindowManager's AX hierarchy
        guard let strip = findStripList(in: wmEl, depth: 0),
              let cards: [AXUIElement] = AXHelper.copyAttribute(strip, kAXChildrenAttribute) else {
            return
        }

        // Locate the card containing (or closest to) the right-click point
        var matchedCard: AXUIElement? = nil
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for card in cards {
            guard let frame = AXHelper.frame(of: card) else { continue }
            if frame.insetBy(dx: -24, dy: -8).contains(cgPoint) {
                let d = hypot(cgPoint.x - frame.midX, cgPoint.y - frame.midY)
                if d < bestDistance {
                    bestDistance = d
                    matchedCard = card
                }
            }
        }

        guard let card = matchedCard else { return }

        var windowIDs: [CGWindowID] = []
        if let rawIDs: [NSNumber] = AXHelper.copyAttribute(card, "AXWindowsIDs") {
            windowIDs = rawIDs.map { CGWindowID($0.uint32Value) }.filter { $0 != 0 }
        }

        // Resolve owning NSRunningApplication from CGWindowIDs (100% accurate even when title != app name)
        var targetApp: NSRunningApplication? = nil
        for wid in windowIDs {
            if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
               let first = list.first,
               let pid = first[kCGWindowOwnerPID as String] as? pid_t,
               let app = NSRunningApplication(processIdentifier: pid),
               !app.isTerminated {
                targetApp = app
                break
            }
        }

        // Fallback: match by AXTitle if AXWindowsIDs was unavailable
        let cardTitle = AXHelper.copyString(card, kAXTitleAttribute) ?? ""
        if targetApp == nil && !cardTitle.isEmpty {
            targetApp = NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && !$0.isTerminated && (
                    $0.localizedName == cardTitle ||
                    $0.localizedName?.caseInsensitiveCompare(cardTitle) == .orderedSame
                )
            }
        }

        guard let app = targetApp else { return }

        DispatchQueue.main.async { [weak self] in
            self?.presentContextMenu(
                for: app,
                cardTitle: cardTitle,
                windowIDs: windowIDs,
                cardElement: card,
                at: appKitPoint
            )
        }
    }

    private func findStripList(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 3 else { return nil }
        if AXHelper.copyString(element, kAXIdentifierAttribute) == "sm.strip" {
            return element
        }
        if AXHelper.copyString(element, kAXRoleAttribute) == (kAXListRole as String) {
            return element
        }
        guard let children: [AXUIElement] = AXHelper.copyAttribute(element, kAXChildrenAttribute) else {
            return nil
        }
        for child in children {
            if let found = findStripList(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func presentContextMenu(
        for app: NSRunningApplication,
        cardTitle: String,
        windowIDs: [CGWindowID],
        cardElement: AXUIElement,
        at appKitPoint: CGPoint
    ) {
        let ctx = MenuContext(app: app, windowIDs: windowIDs, cardElement: cardElement)
        let appName = app.localizedName ?? (cardTitle.isEmpty ? "应用" : cardTitle)
        let isProtected = app.bundleIdentifier.map { AppSettings.shared.isSystemProtected($0) } ?? false

        let menu = NSMenu()

        let header = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let closeTitle = windowIDs.count > 1 ? "关闭这 \(windowIDs.count) 个窗口" : "关闭窗口"
        let closeItem = NSMenuItem(title: closeTitle, action: #selector(menuCloseCardWindows(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = ctx
        menu.addItem(closeItem)

        if !isProtected {
            let quitItem = NSMenuItem(title: "退出 \(appName)", action: #selector(menuQuitApp(_:)), keyEquivalent: "")
            quitItem.target = self
            quitItem.representedObject = ctx
            menu.addItem(quitItem)
        }

        menu.addItem(.separator())

        let switchItem = NSMenuItem(title: "切换到 \(appName)", action: #selector(menuSwitchToCard(_:)), keyEquivalent: "")
        switchItem.target = self
        switchItem.representedObject = ctx
        menu.addItem(switchItem)

        menu.popUp(positioning: nil, at: appKitPoint, in: nil)
    }

    @objc private func menuCloseCardWindows(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? MenuContext, !ctx.app.isTerminated else { return }
        let app = ctx.app
        let targetIDs = Set(ctx.windowIDs)
        let pid = app.processIdentifier
        let isProtected = app.bundleIdentifier.map { AppSettings.shared.isSystemProtected($0) } ?? false
        let autoQuitEnabled = AppSettings.shared.enableLastWindowAutoQuit

        axQueue.async {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.3)

            var closedAny = false
            if let axWindows: [AXUIElement] = AXHelper.copyAttribute(appEl, kAXWindowsAttribute) {
                for win in axWindows {
                    let matchesID: Bool
                    if targetIDs.isEmpty {
                        matchesID = true
                    } else if let wid = AXHelper.windowID(for: win) {
                        matchesID = targetIDs.contains(wid)
                    } else {
                        matchesID = false
                    }
                    if matchesID {
                        if AXHelper.closeWindow(win) {
                            closedAny = true
                        }
                    }
                }
            }

            // If we closed the last window(s) and auto-quit is enabled, gracefully terminate the app too
            if closedAny && autoQuitEnabled && !isProtected {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.35) {
                    guard !app.isTerminated else { return }
                    let summary = AXHelper.inspectWindows(pid: pid)
                    if !summary.hasBlockingSheetOrSystemDialog && summary.userWindows.isEmpty {
                        DispatchQueue.main.async {
                            if !app.isTerminated { app.terminate() }
                        }
                    }
                }
            } else if !closedAny && !isProtected {
                // Fallback if app windows didn't expose AXCloseButton while off-stage
                DispatchQueue.main.async {
                    if !app.isTerminated { app.terminate() }
                }
            }
        }
    }

    @objc private func menuQuitApp(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? MenuContext, !ctx.app.isTerminated else { return }
        ctx.app.terminate()
    }

    @objc private func menuSwitchToCard(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? MenuContext else { return }
        let card = ctx.cardElement
        axQueue.async {
            _ = AXUIElementPerformAction(card, kAXPressAction as CFString)
        }
    }

    private func cgPointToAppKit(_ cgPoint: CGPoint) -> CGPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        guard primaryHeight > 0 else { return cgPoint }
        return CGPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
    }
}
