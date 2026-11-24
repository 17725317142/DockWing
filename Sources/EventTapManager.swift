import AppKit
import CoreGraphics
import Foundation

final class EventTapManager {
    static let shared = EventTapManager()

    private let dockMinimizer = DockClickMinimizer()
    private let autoQuitter = LastWindowAutoQuitter()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    private(set) var isTapActive: Bool = false {
        didSet {
            if oldValue != isTapActive {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .dockWingEventTapStatusChanged, object: nil)
                }
            }
        }
    }

    private init() {}

    func start() {
        setupObservers()
        ensureTapRunning()
        startWatchdog()
    }

    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        tearDownTap()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        NotificationCenter.default.removeObserver(self)
    }

    func ensureTapRunning() {
        guard AXHelper.isAccessibilityTrusted(prompt: false) else {
            tearDownTap()
            isTapActive = false
            return
        }

        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            isTapActive = CGEvent.tapIsEnabled(tap: tap)
            if isTapActive { return }
            tearDownTap()
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            isTapActive = false
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isTapActive = CGEvent.tapIsEnabled(tap: tap)
    }

    private func tearDownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        dockMinimizer.clearPending()
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                isTapActive = CGEvent.tapIsEnabled(tap: tap)
            }
            dockMinimizer.clearPending()
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            let point = event.location
            // Never interfere with clicks landing inside our own hover picker panel
            if DockHoverWindowPicker.shared.isPanelVisibleAndContains(cgPoint: point) {
                dockMinimizer.clearPending()
                return Unmanaged.passUnretained(event)
            }
            if AXHelper.isPointInDockEdgeBand(point) {
                dockMinimizer.handleMouseDown(at: point, flags: event.flags)
            } else {
                dockMinimizer.clearPending()
            }
            // Always allow autoQuitter to check layer == 0 windows (works even when Dock is on the left!)
            autoQuitter.handleMouseDown(at: point)
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            let point = event.location
            dockMinimizer.handleMouseUp(at: point, flags: event.flags)
            autoQuitter.handleMouseUp(at: point)
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 { // Escape dismisses open hover window picker cleanly
                DockHoverWindowPicker.shared.hideIfVisible()
            } else if keyCode == 13 && AppSettings.shared.enableCmdWAutoQuit && AppSettings.shared.enableLastWindowAutoQuit {
                let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
                if mods == .maskCommand {
                    autoQuitter.handleCmdWKeyDown()
                }
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func setupObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        let wakeObs = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AXHelper.invalidateDockCache()
            DockHoverWindowPicker.shared.hideNow()
            NotchMissionControlTrigger.shared.cancelPending()
            NotchMissionControlTrigger.shared.refreshNotchGeometry()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.ensureTapRunning()
            }
        }
        workspaceObservers.append(wakeObs)

        let sleepObs = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            DockHoverWindowPicker.shared.hideNow()
            NotchMissionControlTrigger.shared.cancelPending()
        }
        workspaceObservers.append(sleepObs)

        let spaceObs = wsCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            DockHoverWindowPicker.shared.hideNow()
        }
        workspaceObservers.append(spaceObs)

        let launchObs = wsCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == "com.apple.dock" {
                AXHelper.invalidateDockCache()
                self?.ensureTapRunning()
            }
        }
        workspaceObservers.append(launchObs)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenChanged() {
        AXHelper.invalidateDockCache()
        DockHoverWindowPicker.shared.hideNow()
        NotchMissionControlTrigger.shared.cancelPending()
        NotchMissionControlTrigger.shared.refreshNotchGeometry()
        ensureTapRunning()
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let interval: TimeInterval = isTapActive ? 15.0 : 2.0
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let wasActive = self.isTapActive
            if !self.isTapActive {
                self.ensureTapRunning()
            } else if let tap = self.eventTap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                self.isTapActive = CGEvent.tapIsEnabled(tap: tap)
            }
            if wasActive != self.isTapActive {
                self.startWatchdog()
            }
        }
        watchdogTimer?.tolerance = isTapActive ? 5.0 : 0.5
    }
}
