import AppKit
import CoreGraphics
import Foundation

final class LastWindowAutoQuitter {
    private let workQueue = DispatchQueue(label: "com.dockwing.app.autoQuit", qos: .userInitiated)

    private struct PendingClose {
        let pid: pid_t
        let downPoint: CGPoint
        let downTime: CFTimeInterval
    }

    // Accessed exclusively on workQueue (no lock contention needed)
    private var pendingClose: PendingClose?
    private var scheduledQuitWorkItems: [pid_t: DispatchWorkItem] = [:]

    /// Called asynchronously from mouseDown. Never blocks the event tap.
    /// Safe even when Dock is on the left/right/bottom because closeButtonInfo filters for layer == 0 app windows only.
    func handleMouseDown(at cgPoint: CGPoint) {
        guard AppSettings.shared.enableLastWindowAutoQuit else { return }

        let now = CACurrentMediaTime()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard let info = AXHelper.closeButtonInfo(at: cgPoint), info.isUserWindow else {
                self.pendingClose = nil
                return
            }

            guard let app = NSRunningApplication(processIdentifier: info.pid),
                  self.isEligibleForAutoQuit(app) else {
                self.pendingClose = nil
                return
            }

            self.pendingClose = PendingClose(pid: info.pid, downPoint: cgPoint, downTime: now)
        }
    }

    /// Called asynchronously from mouseUp. Never suppresses the mouseUp event.
    func handleMouseUp(at cgPoint: CGPoint) {
        guard AppSettings.shared.enableLastWindowAutoQuit else { return }

        let upTime = CACurrentMediaTime()
        workQueue.async { [weak self] in
            guard let self = self, let pending = self.pendingClose else { return }
            self.pendingClose = nil

            // Ensure the user actually released on/near the red close button (didn't drag away to cancel)
            let distance = hypot(cgPoint.x - pending.downPoint.x, cgPoint.y - pending.downPoint.y)
            let duration = upTime - pending.downTime
            guard distance < 24.0, duration < 1.5 else { return }

            self.scheduleVerificationAndQuit(pid: pending.pid, delay: 0.34)
        }
    }

    /// Optional: handle Cmd+W when enabled in settings. Never suppresses the key event.
    func handleCmdWKeyDown() {
        guard AppSettings.shared.enableLastWindowAutoQuit,
              AppSettings.shared.enableCmdWAutoQuit else { return }

        guard let front = NSWorkspace.shared.frontmostApplication,
              isEligibleForAutoQuit(front) else { return }

        let pid = front.processIdentifier
        workQueue.async { [weak self] in
            guard let self = self else { return }
            // Only arm auto-quit if the app currently has exactly 1 window before Cmd+W closes it
            let before = AXHelper.inspectWindows(pid: pid)
            guard before.userWindows.count == 1, !before.hasBlockingSheetOrSystemDialog else { return }

            self.scheduleVerificationAndQuit(pid: pid, delay: 0.34)
        }
    }

    private func scheduleVerificationAndQuit(pid: pid_t, delay: TimeInterval) {
        scheduledQuitWorkItems[pid]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.scheduledQuitWorkItems.removeValue(forKey: pid)
            self.verifyAndTerminateIfLastWindowClosed(pid: pid)
        }
        scheduledQuitWorkItems[pid] = item
        workQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func verifyAndTerminateIfLastWindowClosed(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              isEligibleForAutoQuit(app) else {
            return
        }

        let summary = AXHelper.inspectWindows(pid: pid)

        // Abort if there is a "Save changes?" sheet/system dialog or any remaining user window (including minimized ones)
        guard !summary.hasBlockingSheetOrSystemDialog else { return }
        guard summary.userWindows.isEmpty else { return }

        // Graceful quit (preserves unsaved document prompts if any app triggers them on terminate)
        DispatchQueue.main.async {
            if !app.isTerminated {
                app.terminate()
            }
        }
    }

    private func isEligibleForAutoQuit(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              !app.isTerminated,
              let bid = app.bundleIdentifier else {
            return false
        }
        return !AppSettings.shared.isSystemProtected(bid)
    }
}
