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

        let minItem = NSMenuItem(title: "点图标最小化窗口", action: #selector(toggleMinimize), keyEquivalent: "")
        minItem.target = self
        minItem.state = settings.enableDockClickMinimize ? .on : .off
        menu.addItem(minItem)

        let hoverItem = NSMenuItem(title: "悬停多窗口切页", action: #selector(toggleHoverPicker), keyEquivalent: "")
        hoverItem.target = self
        hoverItem.state = settings.enableDockHoverWindowPicker ? .on : .off
        menu.addItem(hoverItem)

        let notchItem = NSMenuItem(title: "刘海 0.15s 切桌面", action: #selector(toggleNotchMissionControl), keyEquivalent: "")
        notchItem.target = self
        notchItem.state = settings.enableNotchMissionControl ? .on : .off
        menu.addItem(notchItem)

        let quitItem = NSMenuItem(title: "关最后窗口退出软件", action: #selector(toggleAutoQuit), keyEquivalent: "")
        quitItem.target = self
        quitItem.state = settings.enableLastWindowAutoQuit ? .on : .off
        menu.addItem(quitItem)

        let cmdWItem = NSMenuItem(title: "按 ⌘W 关末窗也退出", action: #selector(toggleCmdW), keyEquivalent: "")
        cmdWItem.target = self
        cmdWItem.state = settings.enableCmdWAutoQuit ? .on : .off
        cmdWItem.isEnabled = settings.enableLastWindowAutoQuit
        menu.addItem(cmdWItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = settings.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let exitItem = NSMenuItem(title: "退出 DockWing", action: #selector(quitSelf), keyEquivalent: "q")
        exitItem.target = self
        menu.addItem(exitItem)
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
