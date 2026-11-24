import AppKit
import CoreGraphics
import Foundation

/// Ultra-lightweight smooth scroll engine for physical mouse scroll wheels.
/// - Strictly ignores trackpads and Magic Mouse (only intercepts discrete non-continuous wheel ticks).
/// - Zero idle CPU: animation timer is created on demand and destroyed immediately once scrolling settles (~250ms).
/// - Replaces macOS's sluggish/jumpy mouse wheel curve with a crisp, controllable, trackpad-like pixel glide.
final class SmoothScrollEngine {
    static let shared = SmoothScrollEngine()

    /// Unique user-data tag stamped on synthetic scroll events so our CGEventTap never re-intercepts them.
    static let syntheticEventTag: Int64 = 0x4457_5353 // "DWSS"

    private let queue = DispatchQueue(label: "com.dockwing.app.smoothScroll", qos: .userInteractive)

    // Accessed exclusively on `queue`
    private var timer: DispatchSourceTimer?
    private var remainingY: Double = 0
    private var remainingX: Double = 0
    private var residualY: Double = 0
    private var residualX: Double = 0
    private var lastTickTime: CFTimeInterval = 0
    private var lastInputTime: CFTimeInterval = 0
    private var consecutiveFastTicks: Double = 0

    // Apps that natively zoom via Control + scroll wheel (rather than Command + '=' / '-')
    private static let nativeCtrlScrollZoomBundleIDs: Set<String> = [
        "com.microsoft.Excel",
        "com.microsoft.Word",
        "com.microsoft.Powerpoint"
    ]

    // Exponential decay time constant (seconds): ~52ms feels silky like macOS trackpad yet stops crisply
    private let decayTau: Double = 0.052
    private var cachedRefreshRate: Double = 60.0
    private var lastZoomTime: CFTimeInterval = 0

    private init() {
        refreshDisplayRate()
    }

    func refreshDisplayRate() {
        let rate: Double
        if let screen = NSScreen.main ?? NSScreen.screens.first, screen.maximumFramesPerSecond > 0 {
            rate = Double(min(screen.maximumFramesPerSecond, 120))
        } else {
            rate = 60.0
        }
        queue.async { [weak self] in
            self?.cachedRefreshRate = rate
        }
    }

    func stopImmediately() {
        queue.async { [weak self] in
            self?.resetStateLocked()
        }
    }

    /// Called from CGEventTap on `.scrollWheel`.
    /// Returns `true` if the raw discrete wheel tick was consumed and replaced by smooth pixel scrolling.
    func handleScrollWheelEvent(_ event: CGEvent) -> Bool {
        // 1. Never re-process our own synthetic smooth frames
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
            return false
        }

        // 2. Strictly touch physical discrete mouse wheels ONLY — leave trackpad / Magic Mouse 100% untouched!
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        guard isContinuous == 0, scrollPhase == 0, momentumPhase == 0 else {
            return false
        }

        // 3. Handle Command + Wheel or Control + Wheel zoom across browsers, Excel/Office, Preview, etc.
        let relevantMods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if AppSettings.shared.enableModifierWheelZoom && (relevantMods == .maskCommand || relevantMods == .maskControl) {
            return handleModifierWheelZoom(event: event, modifier: relevantMods)
        }

        guard AppSettings.shared.enableSmoothScroll else {
            return false
        }

        // Respect other modifier combinations (e.g. Option + wheel) without smoothing interference
        let passThroughMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        guard event.flags.intersection(passThroughMods).isEmpty else {
            return false
        }

        // Read discrete line deltas (use fixed-point fallback if line delta is 0 on high-res wheels)
        var rawY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        var rawX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))

        if rawY == 0 && rawX == 0 {
            rawY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            rawX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        }
        guard rawY != 0 || rawX != 0 else { return false }

        // Shift + vertical wheel -> smooth horizontal scroll
        if event.flags.contains(.maskShift) && rawX == 0 && rawY != 0 {
            rawX = rawY
            rawY = 0
        }

        let basePixels = AppSettings.shared.scrollSpeedPreset.basePixelsPerNotch
        let now = CACurrentMediaTime()

        queue.async { [weak self] in
            self?.enqueueInput(rawY: rawY, rawX: rawX, basePixels: basePixels, timestamp: now)
        }

        // Suppress the original jumpy discrete line event
        return true
    }

    private func enqueueInput(rawY: Double, rawX: Double, basePixels: Double, timestamp: CFTimeInterval) {
        let dt = timestamp - lastInputTime
        lastInputTime = timestamp

        // Gentle, predictable modern acceleration curve:
        // - Slow deliberate ticks (dt >= 0.16s): crisp 1.0x precision (no sluggish start)
        // - Continuous rolling: smoothly scales up to 2.6x for effortless long-page scrolling
        if dt > 0 && dt < 0.16 {
            let speedBoost = min(1.0, (0.16 - dt) / 0.12)
            consecutiveFastTicks = min(5.0, consecutiveFastTicks + 0.55 + speedBoost * 0.65)
        } else {
            consecutiveFastTicks = 0
        }
        let accelMultiplier = 1.0 + min(1.8, consecutiveFastTicks * 0.32)

        // Normalize raw notch count (clamp wild macOS spike values so it never jumps uncontrollably)
        let normY = clampNotch(rawY)
        let normX = clampNotch(rawX)

        let deltaY = normY * basePixels * accelMultiplier
        let deltaX = normX * basePixels * accelMultiplier

        // Instant reverse braking: reversing scroll direction cancels leftover opposite momentum immediately
        if (deltaY > 0 && remainingY < 0) || (deltaY < 0 && remainingY > 0) {
            remainingY = 0
            residualY = 0
        }
        if (deltaX > 0 && remainingX < 0) || (deltaX < 0 && remainingX > 0) {
            remainingX = 0
            residualX = 0
        }

        // Cap maximum queued distance so fast flicks feel snappy without endless coasting
        let maxQueue = basePixels * 14.0
        remainingY = max(-maxQueue, min(maxQueue, remainingY + deltaY))
        remainingX = max(-maxQueue, min(maxQueue, remainingX + deltaX))

        ensureTimerRunning(now: timestamp)
    }

    private func clampNotch(_ raw: Double) -> Double {
        if raw == 0 { return 0 }
        let sign = raw > 0 ? 1.0 : -1.0
        // Single hardware click on macOS sometimes reports +/-1..+/-3 depending on system scaling;
        // compress gently with sqrt so slow scrolling is rock-steady and fast bursts stay smooth.
        let mag = abs(raw)
        let shaped = mag <= 1.0 ? mag : (1.0 + sqrt(mag - 1.0) * 0.65)
        return sign * min(shaped, 3.0)
    }

    private func ensureTimerRunning(now: CFTimeInterval) {
        guard timer == nil else { return }

        lastTickTime = now
        let fps = max(60.0, cachedRefreshRate)
        let intervalNs = UInt64((1_000_000_000.0 / fps).rounded())

        let t = DispatchSource.makeTimerSource(flags: [], queue: queue)
        t.schedule(
            deadline: .now() + .milliseconds(4),
            repeating: .nanoseconds(Int(intervalNs)),
            leeway: .milliseconds(1)
        )
        t.setEventHandler { [weak self] in
            self?.stepFrame()
        }
        timer = t
        t.resume()
    }

    private func stepFrame() {
        let now = CACurrentMediaTime()
        let rawDt = now - lastTickTime
        lastTickTime = now
        let dt = max(0.004, min(0.05, rawDt))

        // Exponential decay factor: silky smooth deceleration independent of 60Hz vs 120Hz display
        let factor = 1.0 - exp(-dt / decayTau)

        let stepY = remainingY * factor
        let stepX = remainingX * factor

        remainingY -= stepY
        remainingX -= stepX

        // Accumulate sub-pixel fractions so final pixels glide smoothly without truncating to zero prematurely
        residualY += stepY
        residualX += stepX

        let emitY = Int64(residualY.rounded(.towardZero))
        let emitX = Int64(residualX.rounded(.towardZero))

        if emitY != 0 { residualY -= Double(emitY) }
        if emitX != 0 { residualX -= Double(emitX) }

        if emitY != 0 || emitX != 0 {
            postSmoothPixelScroll(pixelY: emitY, pixelX: emitX)
        }

        // Settle and completely destroy timer once remaining motion is sub-pixel -> 0.0% idle CPU!
        if abs(remainingY) < 0.35 && abs(remainingX) < 0.35 && abs(residualY) < 0.5 && abs(residualX) < 0.5 {
            resetStateLocked()
        }
    }

    private func postSmoothPixelScroll(pixelY: Int64, pixelX: Int64) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: pixelY),
            wheel2: Int32(clamping: pixelX),
            wheel3: 0
        ) else {
            return
        }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pixelY)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pixelX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(pixelY))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(pixelX))
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        if pixelX != 0 && pixelY == 0 {
            event.flags.remove(.maskShift)
        }

        event.post(tap: .cgSessionEventTap)
    }

    /// Translates Command+Wheel / Control+Wheel into native zoom for both browsers/general apps (Cmd+= / Cmd+-)
    /// and Microsoft Office apps like Excel/Word/PowerPoint (native Control+Wheel).
    private func handleModifierWheelZoom(event: CGEvent, modifier: CGEventFlags) -> Bool {
        stopImmediately()
        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        // Microsoft Excel / Word / PowerPoint natively zoom on Control + Wheel (they do NOT support Cmd+= / Cmd+-).
        if Self.nativeCtrlScrollZoomBundleIDs.contains(frontBundleID) {
            if modifier == .maskCommand {
                // Rewrite Command flag -> Control flag in place so Cmd+Wheel zooms Excel natively!
                var updatedFlags = event.flags
                updatedFlags.remove(.maskCommand)
                updatedFlags.insert(.maskControl)
                event.flags = updatedFlags
            }
            return false // Pass through to Excel/Word/PowerPoint
        }

        var rawDelta = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        if rawDelta == 0 {
            rawDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        }
        guard rawDelta != 0 else { return true }

        // Mild throttle (65ms) so one deliberate wheel notch produces one crisp zoom step
        let now = CACurrentMediaTime()
        if now - lastZoomTime < 0.065 {
            return true
        }
        lastZoomTime = now

        // Respect physical wheel direction regardless of macOS "Natural scrolling" toggle:
        // Pushing the wheel forward (away from user) ALWAYS zooms in; pulling back ALWAYS zooms out.
        let naturalScrolling = UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
        let zoomIn = naturalScrolling ? (rawDelta < 0) : (rawDelta > 0)

        // macOS virtual keyCodes: 24 = '=' ('+'), 27 = '-'
        let keyCode: CGKeyCode = zoomIn ? 24 : 27
        postCommandKey(keyCode: keyCode)
        return true
    }

    private func postCommandKey(keyCode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        // Explicitly set ONLY Command flag so physically held Control key never pollutes the shortcut
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)

        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private func resetStateLocked() {
        timer?.cancel()
        timer = nil
        remainingY = 0
        remainingX = 0
        residualY = 0
        residualX = 0
        consecutiveFastTicks = 0
    }
}
