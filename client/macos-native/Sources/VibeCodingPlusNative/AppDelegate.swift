import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureWindows()
        createStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func refreshStatusMenu() {
        let menu = NSMenu()
        let state = (appState?.serviceRunning == true) ? "运行中" : "已停止"

        menu.addItem(NSMenuItem(title: "VibeCoding Plus · \(state)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: "显示窗口", action: #selector(showWindow))

        menu.addItem(.separator())
        addMenuItem(to: menu, title: "启动服务", action: #selector(startService))
        addMenuItem(to: menu, title: "重启服务", action: #selector(restartService))
        addMenuItem(to: menu, title: "停止服务", action: #selector(stopService))

        menu.addItem(.separator())
        let launchItem = addMenuItem(to: menu, title: "开机启动", action: #selector(toggleAutoLaunch))
        launchItem.state = appState?.desktopSettings.autoLaunch == true ? .on : .off

        let hiddenItem = addMenuItem(to: menu, title: "启动时隐藏", action: #selector(toggleLaunchToTray))
        hiddenItem.state = appState?.desktopSettings.launchToTray == true ? .on : .off

        let closeToTrayItem = addMenuItem(to: menu, title: "关闭时最小化", action: #selector(toggleCloseToTray))
        closeToTrayItem.state = appState?.desktopSettings.closeToTray == true ? .on : .off

        menu.addItem(.separator())
        addMenuItem(to: menu, title: "打开配置目录", action: #selector(openConfigFolder))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: "退出", action: #selector(quit), keyEquivalent: "q")

        statusMenu = menu
    }

    @discardableResult
    private func addMenuItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
        return item
    }

    func configureWindows() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let launchToTray = self.appState?.desktopSettings.launchToTray == true
            for window in NSApp.windows where !(window is NSPanel) {
                window.title = "VibeCoding Plus"
                window.titlebarAppearsTransparent = true
                window.toolbarStyle = .unifiedCompact
                window.isMovableByWindowBackground = true
                window.minSize = NSSize(width: 980, height: 680)
                window.isReleasedWhenClosed = false
                window.delegate = self
                if launchToTray {
                    window.orderOut(nil)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "VibeCoding Plus")
        item.button?.image?.isTemplate = true
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        refreshStatusMenu()
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            if let button = statusItem?.button, let menu = statusMenu {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            }
            return
        }
        showWindow()
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.setIsVisible(true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else if let window = retainedWindow {
            window.setIsVisible(true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var retainedWindow: NSWindow?

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, !(window is NSPanel) {
            retainedWindow = window
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        retainedWindow = sender
        sender.orderOut(nil)
        return false
    }

    @objc private func startService() {
        Task { @MainActor in await appState?.startService(); refreshStatusMenu() }
    }

    @objc private func restartService() {
        Task { @MainActor in await appState?.restartService(); refreshStatusMenu() }
    }

    @objc private func stopService() {
        Task { @MainActor in await appState?.stopService(); refreshStatusMenu() }
    }

    @objc private func toggleAutoLaunch() {
        Task { @MainActor in
            appState?.desktopSettings.autoLaunch.toggle()
            await appState?.saveSettings(restart: false)
            refreshStatusMenu()
        }
    }

    @objc private func toggleLaunchToTray() {
        Task { @MainActor in
            appState?.desktopSettings.launchToTray.toggle()
            await appState?.saveSettings(restart: false)
            refreshStatusMenu()
        }
    }

    @objc private func toggleCloseToTray() {
        Task { @MainActor in
            appState?.desktopSettings.closeToTray.toggle()
            await appState?.saveSettings(restart: false)
            refreshStatusMenu()
        }
    }

    @objc private func openConfigFolder() {
        Task { @MainActor in appState?.openConfigFolder() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
