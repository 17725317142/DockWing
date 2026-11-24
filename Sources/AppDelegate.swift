import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pure background menu-bar agent: zero SwiftUI, zero extra windows, minimal RAM
        NSApp.setActivationPolicy(.accessory)

        // Single-instance guard
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppSettings.selfBundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTapStatusChanged),
            name: .dockWingEventTapStatusChanged,
            object: nil
        )

        EventTapManager.shared.start()
        DockHoverWindowPicker.shared.start()

        if !AXHelper.isAccessibilityTrusted(prompt: false) {
            _ = AXHelper.isAccessibilityTrusted(prompt: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SmoothScrollEngine.shared.stopImmediately()
        MiddleButtonDragScroller.shared.cancel()
        NotchMissionControlTrigger.shared.cancelPending()
        DockHoverWindowPicker.shared.stop()
        EventTapManager.shared.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(for: item)

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func updateStatusIcon(for item: NSStatusItem?) {
        guard let button = item?.button else { return }
        let active = EventTapManager.shared.isTapActive
        let symbol = active ? "macwindow.on.rectangle" : "exclamationmark.triangle"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "DockWing")
        img?.isTemplate = true
        button.image = img
        button.toolTip = active ? "DockWing（运行中）" : "DockWing（点此授权）"
    }

    @objc private func handleTapStatusChanged() {
        updateStatusIcon(for: statusItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let settings = AppSettings.shared
        let trusted = AXHelper.isAccessibilityTrusted(prompt: false)
        let active = EventTapManager.shared.isTapActive
        let mem = AppSettings.memoryFootprintMB(pid: getpid())

        if trusted && active {
            let status = NSMenuItem(title: String(format: "DockWing · %.1f MB", mem), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        } else {
            let authItem = NSMenuItem(title: "⚠ 点此开启系统权限", action: #selector(openAuth), keyEquivalent: "")
            authItem.target = self
            menu.addItem(authItem)
        }

        menu.addItem(.separator())

        // Group 1: Dock, Window & Desktop
        let dockGroup = NSMenuItem(title: "程序坞与窗口", action: nil, keyEquivalent: "")
        dockGroup.submenu = buildDockWindowSubmenu(settings: settings)
        menu.addItem(dockGroup)

        // Group 2: Mouse & Scroll
        let mouseGroup = NSMenuItem(title: "鼠标与滚轮", action: nil, keyEquivalent: "")
        mouseGroup.submenu = buildMouseSubmenu(settings: settings)
        menu.addItem(mouseGroup)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = settings.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        let exitItem = NSMenuItem(title: "退出 DockWing", action: #selector(quitSelf), keyEquivalent: "q")
        exitItem.target = self
        menu.addItem(exitItem)
    }

    private func buildDockWindowSubmenu(settings: AppSettings) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(makeToggle("点图标最小化窗口", on: settings.enableDockClickMinimize, action: #selector(toggleMinimize)))
        sub.addItem(makeToggle("悬停多窗口切页", on: settings.enableDockHoverWindowPicker, action: #selector(toggleHoverPicker)))
        sub.addItem(makeToggle("关最后窗口退出软件", on: settings.enableLastWindowAutoQuit, action: #selector(toggleAutoQuit)))

        let cmdW = makeToggle("按 ⌘W 关末窗也退出", on: settings.enableCmdWAutoQuit, action: #selector(toggleCmdW))
        cmdW.isEnabled = settings.enableLastWindowAutoQuit
        sub.addItem(cmdW)

        sub.addItem(.separator())

        sub.addItem(makeToggle("台前调度侧栏右键关闭", on: settings.enableStageManagerRightClick, action: #selector(toggleStageManagerMenu)))
        sub.addItem(makeToggle("刘海 0.1s 切桌面", on: settings.enableNotchMissionControl, action: #selector(toggleNotchMissionControl)))
        return sub
    }

    private func buildMouseSubmenu(settings: AppSettings) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(makeToggle("鼠标滚轮丝滑滚动", on: settings.enableSmoothScroll, action: #selector(toggleSmoothScroll)))

        let speedParent = NSMenuItem(title: "滚动幅度：\(settings.scrollSpeedPreset.title)", action: nil, keyEquivalent: "")
        speedParent.isEnabled = settings.enableSmoothScroll
        let speedSub = NSMenu()
        for preset in ScrollSpeedPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectScrollSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            item.state = (settings.scrollSpeedPreset == preset) ? .on : .off
            speedSub.addItem(item)
        }
        speedParent.submenu = speedSub
        sub.addItem(speedParent)

        sub.addItem(.separator())

        sub.addItem(makeToggle("⌘ / ⌃ + 滚轮放大缩小", on: settings.enableModifierWheelZoom, action: #selector(toggleWheelZoom)))
        sub.addItem(makeToggle("长按滚轮中键拖动页面", on: settings.enableMiddleDragScroll, action: #selector(toggleMiddleDragScroll)))
        return sub
    }

    private func makeToggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func openAuth() {
        _ = AXHelper.isAccessibilityTrusted(prompt: true)
        AXHelper.openAccessibilitySettings()
    }

    @objc private func toggleMinimize() {
        AppSettings.shared.enableDockClickMinimize.toggle()
    }

    @objc private func toggleHoverPicker() {
        AppSettings.shared.enableDockHoverWindowPicker.toggle()
    }

    @objc private func toggleNotchMissionControl() {
        AppSettings.shared.enableNotchMissionControl.toggle()
    }

    @objc private func toggleSmoothScroll() {
        AppSettings.shared.enableSmoothScroll.toggle()
        if !AppSettings.shared.enableSmoothScroll {
            SmoothScrollEngine.shared.stopImmediately()
        }
    }

    @objc private func selectScrollSpeed(_ sender: NSMenuItem) {
        if let preset = ScrollSpeedPreset(rawValue: sender.tag) {
            AppSettings.shared.scrollSpeedPreset = preset
        }
    }

    @objc private func toggleWheelZoom() {
        AppSettings.shared.enableModifierWheelZoom.toggle()
    }

    @objc private func toggleMiddleDragScroll() {
        AppSettings.shared.enableMiddleDragScroll.toggle()
        if !AppSettings.shared.enableMiddleDragScroll {
            MiddleButtonDragScroller.shared.cancel()
        }
    }

    @objc private func toggleStageManagerMenu() {
        AppSettings.shared.enableStageManagerRightClick.toggle()
    }

    @objc private func toggleAutoQuit() {
        AppSettings.shared.enableLastWindowAutoQuit.toggle()
    }

    @objc private func toggleCmdW() {
        AppSettings.shared.enableCmdWAutoQuit.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        AppSettings.shared.setLaunchAtLogin(!AppSettings.shared.launchAtLogin)
    }

    @objc private func quitSelf() {
        NSApp.terminate(nil)
    }
}
