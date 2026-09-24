import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let model = AppModel()

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()

        let hosting = NSHostingController(rootView: RootView(model: model, presentation: .window))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MihomoBar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 520, height: 720))
        window.minSize = NSSize(width: 460, height: 520)
        window.delegate = self
        window.isReleasedWhenClosed = false   // 关闭只是隐藏，下次还要复用
        // 记住用户拖到的位置
        window.setFrameAutosaveName("MihomoBarMainWindow")
        positionOnScreen(window)
        mainWindow = window

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 400, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: RootView(model: model, presentation: .popover))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.lefthalf.filled",
                                   accessibilityDescription: "MihomoBar")
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        // popover 里的「打开主窗口」按钮
        model.onOpenMainWindow = { [weak self] in self?.showMainWindow() }

        // 只监听 showInDock 的变化（不用整个 settings，否则每敲一个字都会触发）
        model.$settings
            .map(\.showInDock)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] showInDock in
                NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
                // 关掉 Dock 图标就意味着退化成纯菜单栏应用，顺手把窗口收起来
                if !showInDock { self?.mainWindow?.orderOut(nil) }
            }
            .store(in: &cancellables)

        model.startPolling()
        updateIcon()

        // 开机自启时不要弹窗打扰；只有用户主动启动才显示主窗口
        if launchedByUser {
            showMainWindow()
        }
    }

    /// 用户双击/`open` 启动时会有 `kAEOpenApplication` 事件，
    /// 由 launchd 拉起的登录项没有 —— 用这个区分，避免开机时弹窗。
    private var launchedByUser: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return true }
        return event.eventID == AEEventID(kAEOpenApplication)
    }

    private func applyActivationPolicy() {
        // Dock 图标开关。改完立刻生效，无需重启。
        NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
    }

    // MARK: - 主窗口

    func showMainWindow() {
        guard let window = mainWindow else { return }
        NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
        positionOnScreen(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 把窗口摆到一个真实可见的位置。
    ///
    /// 不能直接依赖 `NSWindow.center()`：应用尚未激活时 `NSScreen.main` 不可靠，
    /// 实测窗口会被放到 `y = -1237` —— 完全在屏幕上方之外，看起来像“没启动”。
    ///
    /// 这里基于 `visibleFrame` 自己算，并对已有位置做一次可见性校验：
    /// 屏幕插拔或分辨率变化后，恢复出来的旧坐标可能已经不在任何屏幕上了。
    private func positionOnScreen(_ window: NSWindow) {
        let screens = NSScreen.screens
        let screen = window.screen ?? NSScreen.main ?? screens.first
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }

        let size = window.frame.size
        let current = window.frame

        // 窗口至少要有 60×60 落在某块屏幕的可见区域里，否则重新居中
        let minVisible = NSRect(x: current.minX, y: current.minY, width: 60, height: 60)
        let anyOverlap = screens.contains { $0.visibleFrame.intersects(minVisible) }
        guard !anyOverlap else { return }

        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2))
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭窗口不等于退出应用 —— 它还要留在菜单栏继续代理
        guard (notification.object as? NSWindow) === mainWindow else { return }
        if !model.settings.showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// 点 Dock 图标时把窗口找回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: - 菜单栏

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开主窗口", action: #selector(contextOpenWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let toggleTitle = model.status.isRunning ? "停止内核" : "启动内核"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(contextToggleKernel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let dash = NSMenuItem(title: "打开面板", action: #selector(contextOpenDashboard), keyEquivalent: "")
        dash.target = self
        dash.isEnabled = model.status.isRunning
        menu.addItem(dash)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MihomoBar", action: #selector(contextQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // 用完即卸，否则左键也会弹菜单
    }

    @objc private func contextOpenWindow() { showMainWindow() }
    @objc private func contextToggleKernel() { Task { await model.toggleKernel() } }
    @objc private func contextOpenDashboard() { model.openDashboard() }
    @objc private func contextQuit() { NSApp.terminate(nil) }

    private func updateIcon() {
        let symbol: String
        switch model.status {
        case .running:              symbol = "shield.lefthalf.filled"
        case .starting, .stopping:  symbol = "circle.dotted"
        case .stopped:              symbol = "shield"
        case .failed:               symbol = "exclamationmark.triangle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MihomoBar")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "MihomoBar · \(model.status.label)"
    }

    // MARK: - 退出

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 直接退出会把系统留在「代理开着但内核已死」的状态，所以这里同步收尾。
        model.stopPolling()
        if model.systemProxyOn {
            try? SystemProxy.set(enabled: false, port: model.settings.mixedPort)
        }
        model.kernel.stop()

        // 提权内核由助手持有，不随 GUI 退出。如果没收干净会留下 TUN 接口与路由，
        // 下次启动会莫名其妙地失败。这里必须让用户知道。
        if model.kernel.isPrivileged, model.kernel.runningPID != nil {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "特权内核仍在运行"
            alert.informativeText = """
            内核以 root 运行且未能停止，继续退出会留下 TUN 接口与路由占用。

            可以做两件事之一：
            · 取消退出，重试「停止内核」
            · 仍然退出，下次启动 MihomoBar 时会自动收掉它
            """
            alert.addButton(withTitle: "仍然退出")
            alert.addButton(withTitle: "取消退出")
            if alert.runModal() == .alertSecondButtonReturn {
                model.startPolling()
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
