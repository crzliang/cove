import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    /// 程序化移动窗口时置位，避免被 windowDidMove 误判成「用户拖动」
    private var isPositioningProgrammatically = false
    /// 窗口显示后的一小段稳定期内，忽略一切 windowDidMove。
    ///
    /// 必须要有这个：autosave 的恢复本身就会触发一次 windowDidMove，
    /// 如果照单全收，应用自己恢复出来的坐标会被当成「用户的选择」存下来，
    /// 然后下次启动继续沿用它 —— 于是窗口永远卡在某块屏上（实测踩到过）。
    private var windowSettled = false
    private var cancellables = Set<AnyCancellable>()
    private let model = AppModel()

    // 仅供 --dump-menu 使用
    var kernelForDump: Kernel { model.kernel }
    var statusForDump: Kernel.Status { model.status }
    /// 仅供 --dump-menu：把内核状态同步进去，否则菜单里永远显示「已停止」
    func syncStatusForDump() { model.syncStatusFromKernel() }

    var dumpState: String {
        var s = model.status.label
        if model.systemProxyOn { s += " · 系统代理开" }
        s += " · 模式=\(model.mode)"
        return s
    }

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()

        let hosting = NSHostingController(rootView: MainWindow(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MihomoBar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable,
                            .fullSizeContentView, .unifiedTitleAndToolbar]
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 880, height: 620))
        window.minSize = NSSize(width: 760, height: 480)
        window.toolbarStyle = .unified
        // 注意：**不要**加 `.moveToActiveSpace`。
        // 它看起来能解决「应用在别的 Space 被拉起时窗口看不见」，但在多显示器下
        // 「活动 Space」可能是另一块屏，结果是窗口被送到用户没在看的地方。
        // 实测：加上它之后窗口稳定落到外接屏；去掉后正常居中在主屏。
        window.delegate = self
        window.isReleasedWhenClosed = false   // 关闭只是隐藏，下次还要复用
        window.setFrameAutosaveName("MihomoBarMainWindow")
        mainWindow = window

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.lefthalf.filled",
                                   accessibilityDescription: "MihomoBar")
            button.image?.isTemplate = true
        }
        // 用原生下拉菜单而不是 popover 面板。
        // 菜单栏这种位置，条目式列表比自绘面板更快、更符合系统习惯，
        // 也不需要为「点开-点关」维护额外状态。
        // 内容在 menuNeedsUpdate 里按当前状态重建。
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        model.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

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


        // 由用户设置决定是否自动开窗。开机自启时建议关掉，见 showWindowOnLaunch 注释。
        if model.settings.showWindowOnLaunch {
            showMainWindow()
        }
    }

    private func applyActivationPolicy() {
        // Dock 图标开关。改完立刻生效，无需重启。
        NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
    }

    // MARK: - 主窗口

    func showMainWindow() {
        guard let window = mainWindow else { return }
        windowSettled = false

        NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
        // 先激活再 order-front，反过来的话窗口可能被排到后台
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // autosave 的恢复发生在 order-front 时，所以判断放到下一轮 runloop。行为很简单：
        //   * 用户自己拖过窗口 → 尊重系统恢复的位置（只要还在某块屏幕上）
        //   * 用户没拖过       → 居中
        // 后一条是为了避免「应用自己把窗口放到第二块屏 → 自动保存 → 下次启动又
        // “恢复”到第二块屏」这种自说自话。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.model.settings.windowPositionIsUserChosen {
                self.ensureVisible(window)
            } else {
                self.centerOnMainScreen(window)
            }
            // 等摆放彻底稳定后再允许把移动当作「用户拖动」
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.windowSettled = true
            }
        }
    }

    /// 居中到含菜单栏那块屏（frame 原点为 (0,0) 的那块）。
    private func centerOnMainScreen(_ window: NSWindow) {
        let screen = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        setFrameOrigin(window, NSPoint(x: visible.midX - size.width / 2,
                                       y: visible.midY - size.height / 2))
    }

    /// 只在窗口完全不在任何屏幕上时才把它拉回来。
    /// 显示器拔掉、分辨率变化后，恢复出来的旧坐标可能已经无处可去。
    private func ensureVisible(_ window: NSWindow) {
        let probe = NSRect(x: window.frame.minX, y: window.frame.minY, width: 80, height: 80)
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(probe) }) { return }
        centerOnMainScreen(window)
    }

    /// 所有程序化移动都走这里。
    ///
    /// 标志位复位必须放到下一轮 runloop —— `windowDidMove` 是异步派发的，
    /// 同步复位会让紧接着到达的通知被误判成「用户拖动」，于是把应用自己算出来的
    /// 坐标当成用户选择保存下来。
    private func setFrameOrigin(_ window: NSWindow, _ origin: NSPoint) {
        isPositioningProgrammatically = true
        window.setFrameOrigin(origin)
        DispatchQueue.main.async { [weak self] in
            self?.isPositioningProgrammatically = false
        }
    }

    /// 用户真正拖动窗口后才尊重保存的坐标
    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow,
              windowSettled,
              !isPositioningProgrammatically else { return }
        if !model.settings.windowPositionIsUserChosen {
            model.settings.windowPositionIsUserChosen = true
            try? model.settings.save()
        }
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

    // MARK: - 菜单栏下拉菜单

    /// 菜单每次打开时按当前状态重建，不需要额外同步。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 顶部两行是只读状态，用于「扫一眼」
        menu.addItem(disabled("MihomoBar · \(model.status.label)"))
        if model.status.isRunning {
            menu.addItem(disabled("↓ \(TrafficMonitor.rate(model.traffic.down))"
                                  + "    ↑ \(TrafficMonitor.rate(model.traffic.up))"))
        }
        menu.addItem(.separator())

        let power = action(model.status.isRunning ? "停止内核" : "启动内核",
                           #selector(menuToggleKernel),
                           symbol: model.status.isRunning ? "stop.fill" : "play.fill")
        power.isEnabled = !model.status.isBusy && !model.busy
        menu.addItem(power)

        let proxy = action("系统代理", #selector(menuToggleProxy), symbol: "network")
        proxy.state = model.systemProxyOn ? .on : .off
        proxy.isEnabled = model.status.isRunning && !model.busy
        menu.addItem(proxy)

        menu.addItem(modeSubmenu())

        let dash = action("打开浏览器面板", #selector(menuOpenDashboard), symbol: "safari")
        dash.isEnabled = model.status.isRunning
        menu.addItem(dash)

        let reload = action("重载配置", #selector(menuReload), symbol: "arrow.clockwise")
        reload.isEnabled = model.status.isRunning && !model.busy
        menu.addItem(reload)

        menu.addItem(.separator())

        menu.addItem(action("显示主窗口", #selector(menuShowWindow), symbol: "macwindow"))
        menu.addItem(action("数据目录", #selector(menuRevealData), symbol: "folder"))
        if model.needsRestart {
            let restart = action("重启内核（设置已改）", #selector(menuRestart), symbol: "exclamationmark.arrow.triangle.2.circlepath")
            restart.isEnabled = !model.busy && !model.status.isBusy
            menu.addItem(restart)
        }

        menu.addItem(.separator())

        let quit = action("退出 MihomoBar", #selector(menuQuit), symbol: "power")
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    private func modeSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "模式", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        let sub = NSMenu()
        for (title, value) in [("规则", "rule"), ("全局", "global"), ("直连", "direct")] {
            let item = NSMenuItem(title: title, action: #selector(menuSetMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = (model.mode == value) ? .on : .off
            item.isEnabled = model.status.isRunning
            sub.addItem(item)
        }
        parent.submenu = sub
        parent.isEnabled = model.status.isRunning
        return parent
    }

    @objc private func menuToggleKernel()   { Task { await model.toggleKernel() } }
    @objc private func menuToggleProxy()    { Task { await model.setSystemProxy(!model.systemProxyOn) } }
    @objc private func menuOpenDashboard()  { model.openDashboard() }
    @objc private func menuReload()         { Task { await model.reloadConfig() } }
    @objc private func menuShowWindow()     { showMainWindow() }
    @objc private func menuRevealData()     { model.revealDataDir() }
    @objc private func menuQuit()           { NSApp.terminate(nil) }
    @objc private func menuRestart() {
        Task {
            await model.toggleKernel()
            await model.startKernel()
        }
    }
    @objc private func menuSetMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        Task { await model.setMode(value) }
    }

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
