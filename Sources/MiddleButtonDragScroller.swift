import AppKit
import CoreGraphics
import Foundation

/// Press and hold the middle mouse button (wheel click) to grab & pan pages smoothly in any direction
/// (works in browsers, Excel, PDFs, canvases, code editors).
/// - Short middle-clicks (< 180ms and < 4pt movement) are cleanly replayed so opening/closing browser tabs works 100% natively!
/// - Zero idle CPU, zero extra memory.
final class MiddleButtonDragScroller {
    static let shared = MiddleButtonDragScroller()

    private enum State {
        case idle
        case arming
        case dragging
    }

    private var state: State = .idle
    private var downPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var downTime: CFTimeInterval = 0
    private var residualX: Double = 0
    private var residualY: Double = 0

    // Distance/time thresholds separating a short middle-click from a grab-to-pan drag
    private let dragDistanceThreshold: CGFloat = 4.0
    private let holdTimeThreshold: CFTimeInterval = 0.18
    // Pan gain: 1.35x feels effortless on long web pages and wide Excel sheets while staying accurate
    private let panGain: Double = 1.35

    private init() {}

    func cancel() {
        state = .idle
        residualX = 0
        residualY = 0
    }

    /// Returns `true` if the event was consumed.
    func handleOtherMouseEvent(type: CGEventType, event: CGEvent) -> Bool {
        // Ignore our own replayed short middle-clicks
        if event.getIntegerValueField(.eventSourceUserData) == SmoothScrollEngine.syntheticEventTag {
            return false
        }

        // Only handle the middle wheel button (buttonNumber == 2); leave mouse side buttons (3/4) untouched!
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard buttonNumber == 2 else { return false }

        guard AppSettings.shared.enableMiddleDragScroll else {
            if state != .idle { cancel() }
            return false
        }

        let loc = event.location

        switch type {
        case .otherMouseDown:
            SmoothScrollEngine.shared.stopImmediately()
            state = .arming
            downPoint = loc
            lastPoint = loc
            downTime = CACurrentMediaTime()
            residualX = 0
            residualY = 0
            return true

        case .otherMouseDragged:
            guard state != .idle else { return false }

            if state == .arming {
                let dist = hypot(loc.x - downPoint.x, loc.y - downPoint.y)
                let elapsed = CACurrentMediaTime() - downTime
                if dist >= dragDistanceThreshold || elapsed >= holdTimeThreshold {
                    state = .dragging
                    lastPoint = loc
                }
                return true
            }

            // Active grab-and-pan dragging
            let dx = Double(loc.x - lastPoint.x)
            let dy = Double(loc.y - lastPoint.y)
            lastPoint = loc

            // In macOS CoreGraphics screen coordinates (+Y is down, +X is right):
            // Pulling mouse down (dy > 0) -> positive pixelY -> content follows hand downward (natural grab-pan)
            // Pulling mouse right (dx > 0) -> positive pixelX -> content follows hand rightward
            residualX += dx * panGain
            residualY += dy * panGain

            let emitX = Int64(residualX.rounded(.towardZero))
            let emitY = Int64(residualY.rounded(.towardZero))
            if emitX != 0 { residualX -= Double(emitX) }
            if emitY != 0 { residualY -= Double(emitY) }

            if emitX != 0 || emitY != 0 {
                postPanScroll(pixelY: emitY, pixelX: emitX)
            }
            return true

        case .otherMouseUp:
            guard state != .idle else { return false }
            let prevState = state
            let clickPoint = downPoint
            let elapsed = CACurrentMediaTime() - downTime
            let dist = hypot(loc.x - downPoint.x, loc.y - downPoint.y)
            cancel()

            // If user just did a quick middle-click (didn't drag or hold), replay native middle-click
            // so opening links in new tabs / closing tabs continues working seamlessly.
            if prevState == .arming && elapsed < holdTimeThreshold && dist < dragDistanceThreshold {
                replayMiddleClick(at: clickPoint)
            }
            return true

        default:
            return false
        }
    }

    private func postPanScroll(pixelY: Int64, pixelX: Int64) {
        guard let scroll = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: pixelY),
            wheel2: Int32(clamping: pixelX),
            wheel3: 0
        ) else {
            return
        }

        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scroll.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pixelY)
        scroll.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pixelX)
        scroll.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(pixelY))
        scroll.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(pixelX))
        scroll.setIntegerValueField(.eventSourceUserData, value: SmoothScrollEngine.syntheticEventTag)

        scroll.post(tap: .cgSessionEventTap)
    }

    private func replayMiddleClick(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: point, mouseButton: .center),
              let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: point, mouseButton: .center) else {
            return
        }
        down.setIntegerValueField(.eventSourceUserData, value: SmoothScrollEngine.syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: SmoothScrollEngine.syntheticEventTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
