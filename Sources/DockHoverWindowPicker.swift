import AppKit
import CoreGraphics
import Foundation

private final class HoverPickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class WindowRowView: NSView {
    private let entry: AXHelper.WindowEntry
    private let onSelect: () -> Void
    private let onClose: () -> Void

    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let closeButton = FirstMouseButton()
    private let titleLabel = NSTextField(labelWithString: "")

    init(entry: AXHelper.WindowEntry, width: CGFloat, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.entry = entry
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))

        wantsLayer = true
        layer?.cornerRadius = 7

        // Status dot
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        if entry.isFocused {
            dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        } else if entry.isMinimized {
            dot.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.75).cgColor
        } else {
            dot.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor
        }
        addSubview(dot)

        // Window title
        titleLabel.stringValue = entry.isMinimized ? "\(entry.title)（已最小化）" : entry.title
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: entry.isFocused ? .medium : .regular)
        titleLabel.textColor = entry.isMinimized ? .secondaryLabelColor : .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Subtle close button (revealed on hover)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭窗口")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(equalToConstant: width),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
        closeButton.isHidden = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Ensure clicks anywhere on the row (including over NSTextField text or the status dot)
    /// always route directly to WindowRowView instead of being swallowed by non-first-mouse subviews.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden && closeButton.frame.insetBy(dx: -4, dy: -4).contains(local) {
            return closeButton
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !closeButton.isHidden && closeButton.frame.insetBy(dx: -4, dy: -4).contains(local) {
            return
        }
        if bounds.contains(local) {
            onSelect()
        }
    }

    @objc private func closeClicked() {
        onClose()
    }
}

final class DockHoverWindowPicker {
    static let shared = DockHoverWindowPicker()

    private let axQueue = DispatchQueue(label: "com.dockwing.app.hoverPicker", qos: .userInteractive)
    private var mouseMoveMonitor: Any?
    private var mouseDownMonitor: Any?

    private var hoverTimer: DispatchWorkItem?
    private var dismissTimer: DispatchWorkItem?

    private var panel: HoverPickerPanel?
    private var stackView: NSStackView?
    private var headerIconView: NSImageView?
    private var headerTitleLabel: NSTextField?
    private var headerCountLabel: NSTextField?

    private var currentBundleID: String?
    private var currentApp: NSRunningApplication?
    private var currentAnchorRect: CGRect?
    private var currentSnapshotSignature: String = ""
    private var inspectGeneration: UInt64 = 0

    private let panelWidth: CGFloat = 296

    private init() {}

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingChanged),
            name: .dockWingHoverSettingChanged,
            object: nil
        )
        updateMonitoring()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        removeMonitors()
        hideNow()
    }

    func isPanelVisibleAndContains(cgPoint: CGPoint) -> Bool {
        guard let p = panel, p.isVisible else { return false }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        guard primaryHeight > 0 else { return false }
        let appKitPoint = CGPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
        return p.frame.insetBy(dx: -2, dy: -2).contains(appKitPoint)
    }

    func hideIfVisible() {
        if panel?.isVisible == true {
            hideNow()
        }
    }

    func hideNow() {
        hoverTimer?.cancel()
        hoverTimer = nil
        dismissTimer?.cancel()
        dismissTimer = nil
        currentBundleID = nil
        currentApp = nil
        currentAnchorRect = nil
        currentSnapshotSignature = ""
        removeOutsideClickMonitor()

        if let p = panel, p.isVisible {
            p.orderOut(nil)
        }
        headerIconView?.image = nil
        // Release row views & AXUIElement references immediately so idle memory stays flat
        stackView?.arrangedSubviews.forEach { view in
            stackView?.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    @objc private func handleSettingChanged() {
        updateMonitoring()
    }

    private func updateMonitoring() {
        let needsMouseMove = AppSettings.shared.enableDockHoverWindowPicker || AppSettings.shared.enableNotchMissionControl
        if needsMouseMove {
            installMonitorsIfNeeded()
        } else {
            removeMonitors()
        }
        if !AppSettings.shared.enableDockHoverWindowPicker {
            hideNow()
        }
        if !AppSettings.shared.enableNotchMissionControl {
            NotchMissionControlTrigger.shared.cancelPending()
        }
    }

    private func installMonitorsIfNeeded() {
        if mouseMoveMonitor == nil {
            mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                self?.handleMouseMoved()
            }
        }
    }

    private func installOutsideClickMonitorIfNeeded() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.panel, p.isVisible else { return }
            let loc = NSEvent.mouseLocation
            if !p.frame.contains(loc) {
                self.hideNow()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = mouseDownMonitor {
            NSEvent.removeMonitor(m)
            mouseDownMonitor = nil
        }
    }

    private func removeMonitors() {
        if let m = mouseMoveMonitor {
            NSEvent.removeMonitor(m)
            mouseMoveMonitor = nil
        }
        removeOutsideClickMonitor()
    }

    private func handleMouseMoved() {
        let appKitLoc = NSEvent.mouseLocation

        // Share this single global mouseMoved monitor with the notch Mission Control trigger (O(1) rect check)
        NotchMissionControlTrigger.shared.handleMouseMoved(at: appKitLoc)

        guard AppSettings.shared.enableDockHoverWindowPicker,
              EventTapManager.shared.isTapActive else {
            return
        }

        // 1. If the picker panel is currently visible, check whether the cursor is still inside
        // the panel or the safe bridge between the Dock icon and the panel
        if let p = panel, p.isVisible {
            if p.frame.insetBy(dx: -6, dy: -6).contains(appKitLoc) {
                dismissTimer?.cancel()
                dismissTimer = nil
                hoverTimer?.cancel()
                hoverTimer = nil
                return
            }
            if let anchor = currentAnchorRect {
                let bridge = anchor.union(p.frame).insetBy(dx: -12, dy: -8)
                if bridge.contains(appKitLoc) {
                    dismissTimer?.cancel()
                    dismissTimer = nil
                    // Still allow switching smoothly if the user moves horizontally onto another Dock icon
                    let cgLoc = appKitPointToCG(appKitLoc)
                    if AXHelper.isPointInDockEdgeBand(cgLoc) && !anchor.contains(appKitLoc) {
                        scheduleDockInspect(delay: 0.08)
                    }
                    return
                }
            }
        }

        // 2. Fast O(1) edge check: ignore 99% of mouse movements away from the Dock
        let cgLoc = appKitPointToCG(appKitLoc)
        guard AXHelper.isPointInDockEdgeBand(cgLoc) else {
            hoverTimer?.cancel()
            hoverTimer = nil
            if panel?.isVisible == true {
                scheduleDismiss()
            }
            return
        }

        // 3. Mouse is inside Dock edge band: debounce briefly, then read LIVE cursor position
        let delay: TimeInterval = (panel?.isVisible == true) ? 0.08 : 0.16
        scheduleDockInspect(delay: delay)
    }

    private func scheduleDockInspect(delay: TimeInterval) {
        hoverTimer?.cancel()
        inspectGeneration &+= 1
        let gen = inspectGeneration
        let item = DispatchWorkItem { [weak self] in
            self?.inspectLiveCursorOnDock(generation: gen, retryRemaining: 1)
        }
        hoverTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleDismiss() {
        guard dismissTimer == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.dismissTimer = nil
            self?.hideNow()
        }
        dismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: item)
    }

    private func inspectLiveCursorOnDock(generation: UInt64, retryRemaining: Int) {
        guard generation == inspectGeneration else { return }

        // Always read the LIVE cursor position at trigger time (never a stale position from 160ms ago)
        let appKitLoc = NSEvent.mouseLocation
        let cgPoint = appKitPointToCG(appKitLoc)
        guard AXHelper.isPointInDockEdgeBand(cgPoint) else { return }

        axQueue.async { [weak self] in
            guard let self = self else { return }
            guard let hit = AXHelper.dockTileAt(cgPoint: cgPoint) else {
                // If auto-hidden Dock is still mid-slide-in animation, retry once after 140ms
                if retryRemaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                        self?.inspectLiveCursorOnDock(generation: generation, retryRemaining: retryRemaining - 1)
                    }
                } else {
                    DispatchQueue.main.async { self.scheduleDismiss() }
                }
                return
            }

            let isAppTile = (hit.subrole == "AXApplicationDockItem") || (hit.url?.pathExtension == "app")
            guard isAppTile,
                  let bundleID = hit.bundleID,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) else {
                DispatchQueue.main.async { self.scheduleDismiss() }
                return
            }

            let entries = AXHelper.listStandardWindows(for: app)
            // Strict requirement: only pop up when the app has multiple windows (>= 2)
            guard entries.count >= 2 else {
                DispatchQueue.main.async {
                    if self.panel?.isVisible == true {
                        self.hideNow()
                    }
                }
                return
            }

            let anchorAppKit = hit.frame.map { AXHelper.cgRectToAppKit($0) }
            DispatchQueue.main.async {
                guard generation == self.inspectGeneration else { return }
                self.show(app: app, entries: entries, anchorRect: anchorAppKit)
            }
        }
    }

    private func show(app: NSRunningApplication, entries: [AXHelper.WindowEntry], anchorRect: CGRect?) {
        dismissTimer?.cancel()
        dismissTimer = nil

        let signature = "\(app.bundleIdentifier ?? "")|" + entries.prefix(10).map {
            "\($0.title)|\($0.isMinimized)|\($0.isFocused)"
        }.joined(separator: ";")

        // Skip redundant rebuilds if already displaying the exact same app & window list (zero flicker!)
        if let existing = panel, existing.isVisible, signature == currentSnapshotSignature {
            currentAnchorRect = anchorRect
            return
        }

        currentBundleID = app.bundleIdentifier
        currentApp = app
        currentAnchorRect = anchorRect
        currentSnapshotSignature = signature

        let p = ensurePanel()
        guard let stack = stackView else { return }

        // Downscale header icon to 16pt to avoid retaining huge 1024px icon bitmaps
        if let rawIcon = app.icon {
            let small = NSImage(size: NSSize(width: 16, height: 16))
            small.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            rawIcon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16), from: .zero, operation: .copy, fraction: 1.0)
            small.unlockFocus()
            headerIconView?.image = small
        } else {
            headerIconView?.image = nil
        }
        headerTitleLabel?.stringValue = app.localizedName ?? (app.bundleIdentifier ?? "")
        headerCountLabel?.stringValue = "\(entries.count) 个窗口"

        // Rebuild rows cleanly
        stack.arrangedSubviews.forEach { v in
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let maxVisible = min(entries.count, 10)
        let rowWidth = panelWidth - 16
        for entry in entries.prefix(maxVisible) {
            let row = WindowRowView(
                entry: entry,
                width: rowWidth,
                onSelect: { [weak self] in
                    let targetWindow = entry.element
                    let targetApp = app
                    self?.hideNow()
                    DispatchQueue.global(qos: .userInteractive).async {
                        AXHelper.focusWindow(targetWindow, of: targetApp)
                    }
                },
                onClose: { [weak self] in
                    self?.axQueue.async {
                        _ = AXHelper.closeWindow(entry.element)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                            guard let self = self, self.panel?.isVisible == true else { return }
                            self.refreshCurrentAppAfterClose(app: app, anchorRect: anchorRect)
                        }
                    }
                }
            )
            stack.addArrangedSubview(row)
        }

        // Compute exact compact panel height
        let headerHeight: CGFloat = 34
        let rowsHeight = CGFloat(maxVisible) * 30.0 + CGFloat(max(0, maxVisible - 1)) * 2.0
        let totalHeight = headerHeight + rowsHeight + 14.0

        let origin = computeOrigin(size: NSSize(width: panelWidth, height: totalHeight), anchorRect: anchorRect)
        let targetFrame = NSRect(origin: origin, size: NSSize(width: panelWidth, height: totalHeight))

        p.setFrame(targetFrame, display: true)
        installOutsideClickMonitorIfNeeded()

        if !p.isVisible {
            p.alphaValue = 0.0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 1.0
            }
        } else {
            p.orderFrontRegardless()
        }
    }

    private func refreshCurrentAppAfterClose(app: NSRunningApplication, anchorRect: CGRect?) {
        axQueue.async { [weak self] in
            guard let self = self else { return }
            guard !app.isTerminated else {
                DispatchQueue.main.async { self.hideNow() }
                return
            }
            let remaining = AXHelper.listStandardWindows(for: app)
            DispatchQueue.main.async {
                if remaining.count >= 2 {
                    self.show(app: app, entries: remaining, anchorRect: anchorRect)
                } else {
                    self.hideNow()
                }
            }
        }
    }

    private func ensurePanel() -> HoverPickerPanel {
        if let existing = panel { return existing }

        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: 120)
        let p = HoverPickerPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false

        let effect = NSVisualEffectView(frame: rect)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.75
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        effect.autoresizingMask = [.width, .height]

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(header)

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(iconView)
        self.headerIconView = iconView

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        self.headerTitleLabel = titleLabel

        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(countLabel)
        self.headerCountLabel = countLabel

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(divider)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        self.stackView = stack

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: effect.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 24),

            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),

            stack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 5),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8)
        ])

        p.contentView = effect
        self.panel = p
        return p
    }

    private func computeOrigin(size: NSSize, anchorRect: CGRect?) -> CGPoint {
        let screen = screenFor(anchor: anchorRect) ?? NSScreen.main ?? NSScreen.screens.first!
        let margin: CGFloat = 10
        let orientation = AXHelper.dockOrientation()

        var x: CGFloat
        var y: CGFloat

        if let anchor = anchorRect {
            switch orientation {
            case "left":
                x = anchor.maxX + 12
                y = anchor.midY - size.height / 2
            case "right":
                x = anchor.minX - size.width - 12
                y = anchor.midY - size.height / 2
            default:
                x = anchor.midX - size.width / 2
                y = anchor.maxY + 4
            }
        } else {
            let mouse = NSEvent.mouseLocation
            x = mouse.x - size.width / 2
            y = screen.visibleFrame.minY + 12
        }

        x = max(screen.frame.minX + margin, min(x, screen.frame.maxX - size.width - margin))
        y = max(screen.frame.minY + margin, min(y, screen.frame.maxY - size.height - margin))
        return CGPoint(x: round(x), y: round(y))
    }

    private func screenFor(anchor: CGRect?) -> NSScreen? {
        let pt = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pt) }
    }

    private func appKitPointToCG(_ appKitPoint: CGPoint) -> CGPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        guard primaryHeight > 0 else { return appKitPoint }
        return CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
    }
}
