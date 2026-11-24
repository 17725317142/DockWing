import AppKit
import CoreGraphics
import Foundation

final class DockClickMinimizer {
    /// Serial FIFO queue guarantees handleMouseDown's async work always completes before handleMouseUp's async work,
    /// keeping the CGEventTap callback 100% free of synchronous AX IPC or blocking semaphores.
    private let axQueue = DispatchQueue(label: "com.dockwing.app.dockMinimize", qos: .userInteractive)

    private struct PendingClick {
        let downPoint: CGPoint
        let downTime: CFTimeInterval
        let targetApp: NSRunningApplication
    }

    // Accessed exclusively on axQueue
    private var pending: PendingClick?

    /// Non-blocking observation of leftMouseDown inside the Dock edge band.
    func handleMouseDown(at cgPoint: CGPoint, flags: CGEventFlags) {
        // Never dismiss or hijack clicks that land inside our own hover window picker panel
        if DockHoverWindowPicker.shared.isPanelVisibleAndContains(cgPoint: cgPoint) {
            clearPending()
            return
        }

        // Respect modifier clicks (Cmd-click reveals in Finder, Opt-click hides others, etc.)
        let relevantModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard flags.intersection(relevantModifiers).isEmpty else {
            clearPending()
            return
        }

        // Capture frontmost app & timestamp synchronously (pure memory read, <1us)
        let front = NSWorkspace.shared.frontmostApplication
        let frontBundleID = front?.bundleIdentifier
        let frontIsHidden = front?.isHidden ?? true
        let downTime = CACurrentMediaTime()
        let minimizeEnabled = AppSettings.shared.enableDockClickMinimize

        axQueue.async { [weak self] in
            guard let self = self else { return }
            self.pending = nil

            guard let hit = AXHelper.dockTileAt(cgPoint: cgPoint) else { return }
            // Genuine click on a Dock tile -> dismiss any open hover picker
            DispatchQueue.main.async { DockHoverWindowPicker.shared.hideNow() }

            guard minimizeEnabled else { return }
            let isAppTile = (hit.subrole == "AXApplicationDockItem") || (hit.url?.pathExtension == "app")
            guard isAppTile,
                  let clickedBundleID = hit.bundleID,
                  let frontApp = front,
                  frontBundleID == clickedBundleID,
                  !frontIsHidden else {
                return
            }

            let summary = AXHelper.inspectWindows(pid: frontApp.processIdentifier)
            guard !summary.visibleNonMinimizedWindows.isEmpty else { return }

            self.pending = PendingClick(
                downPoint: cgPoint,
                downTime: downTime,
                targetApp: frontApp
            )
        }
    }

    /// Non-blocking observation of leftMouseUp. Never suppresses the event so Dock always finishes its click cycle cleanly.
    func handleMouseUp(at cgPoint: CGPoint, flags: CGEventFlags) {
        let upTime = CACurrentMediaTime()
        axQueue.async { [weak self] in
            guard let self = self, let click = self.pending else { return }
            self.pending = nil

            guard AppSettings.shared.enableDockClickMinimize else { return }

            let distance = hypot(cgPoint.x - click.downPoint.x, cgPoint.y - click.downPoint.y)
            let duration = upTime - click.downTime
            guard distance < 8.0, duration < 0.38 else { return }

            let targetApp = click.targetApp
            guard !targetApp.isTerminated else { return }

            // Short 45ms delay so native Dock finishes its mouseUp cycle cleanly first
            self.axQueue.asyncAfter(deadline: .now() + .milliseconds(45)) {
                guard !targetApp.isTerminated, !targetApp.isHidden else { return }
                AXHelper.minimizeApp(targetApp)
            }
        }
    }

    func clearPending() {
        axQueue.async { [weak self] in
            self?.pending = nil
        }
    }
}
