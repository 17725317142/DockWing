import AppKit
import Foundation

/// Triggers macOS Mission Control (desktop switcher, same as Control+Up) when the cursor
/// dwells inside the MacBook notch area for 0.5 seconds.
/// Ultra-lightweight: shares the single global mouseMoved monitor with DockHoverWindowPicker,
/// uses cached O(1) notch bounds, zero polling, zero extra memory.
final class NotchMissionControlTrigger {
    static let shared = NotchMissionControlTrigger()

    private let dwellDuration: TimeInterval = 0.1
    private let cooldownDuration: TimeInterval = 0.8

    private var cachedNotchRects: [CGRect] = []
    private var dwellTimer: DispatchWorkItem?
    private var isInsideNotch: Bool = false
    private var hasTriggeredInCurrentVisit: Bool = false
    private var lastTriggerTime: CFTimeInterval = 0

    private init() {
        refreshNotchGeometry()
    }

    func refreshNotchGeometry() {
        var rects: [CGRect] = []
        for screen in NSScreen.screens {
            let safeTop = screen.safeAreaInsets.top
            guard safeTop > 0,
                  let leftAux = screen.auxiliaryTopLeftArea,
                  let rightAux = screen.auxiliaryTopRightArea else {
                continue
            }
            let notchMinX = leftAux.maxX
            let notchMaxX = rightAux.minX
            guard notchMaxX > notchMinX + 20 else { continue }

            // Add a tiny 4pt horizontal tolerance on each side so resting on the notch border feels forgiving,
            // while staying cleanly clear of menu bar items to the left and right.
            let notchRect = CGRect(
                x: notchMinX - 4,
                y: screen.frame.maxY - safeTop - 2,
                width: (notchMaxX - notchMinX) + 8,
                height: safeTop + 6
            )
            rects.append(notchRect)
        }
        cachedNotchRects = rects
    }

    func cancelPending() {
        dwellTimer?.cancel()
        dwellTimer = nil
        isInsideNotch = false
        hasTriggeredInCurrentVisit = false
    }

    /// Called on main thread from the shared global mouseMoved monitor (O(1) pure rect check).
    func handleMouseMoved(at appKitPoint: CGPoint) {
        guard AppSettings.shared.enableNotchMissionControl else {
            if dwellTimer != nil || isInsideNotch { cancelPending() }
            return
        }
        guard !cachedNotchRects.isEmpty else { return }

        // Never trigger while the user is dragging a window or holding any mouse button
        if NSEvent.pressedMouseButtons != 0 {
            if dwellTimer != nil {
                dwellTimer?.cancel()
                dwellTimer = nil
            }
            return
        }

        let inside = isPointInNotch(appKitPoint)

        if inside {
            isInsideNotch = true
            // Already triggered during this hover visit, or dwell countdown already running -> do NOT reset timer!
            guard !hasTriggeredInCurrentVisit, dwellTimer == nil else { return }

            let now = CACurrentMediaTime()
            guard now - lastTriggerTime >= cooldownDuration else { return }

            let item = DispatchWorkItem { [weak self] in
                self?.fireIfStillInsideNotch()
            }
            dwellTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + dwellDuration, execute: item)
        } else {
            // Left the notch -> cancel countdown immediately
            if dwellTimer != nil {
                dwellTimer?.cancel()
                dwellTimer = nil
            }
            // Use a small 10pt exit hysteresis so jitter on the bottom edge of the notch doesn't re-trigger immediately
            if isInsideNotch && !isPointInNotchExitHysteresis(appKitPoint) {
                isInsideNotch = false
                hasTriggeredInCurrentVisit = false
            }
        }
    }

    private func fireIfStillInsideNotch() {
        dwellTimer = nil
        guard AppSettings.shared.enableNotchMissionControl,
              NSEvent.pressedMouseButtons == 0 else {
            return
        }

        let livePoint = NSEvent.mouseLocation
        guard isPointInNotch(livePoint) else {
            isInsideNotch = false
            hasTriggeredInCurrentVisit = false
            return
        }

        hasTriggeredInCurrentVisit = true
        lastTriggerTime = CACurrentMediaTime()

        // Close any open Dock hover picker cleanly before opening Mission Control
        DockHoverWindowPicker.shared.hideIfVisible()
        AXHelper.triggerMissionControl()
    }

    private func isPointInNotch(_ pt: CGPoint) -> Bool {
        for rect in cachedNotchRects where rect.contains(pt) {
            return true
        }
        return false
    }

    private func isPointInNotchExitHysteresis(_ pt: CGPoint) -> Bool {
        for rect in cachedNotchRects where rect.insetBy(dx: -10, dy: -10).contains(pt) {
            return true
        }
        return false
    }
}
