import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻，不进 Dock、不进 Cmd-Tab
        NSApp.setActivationPolicy(.accessory)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 400, height: 560)
        popover.contentViewController = NSHostingController(rootView: RootView(model: model))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.lefthalf.filled",
                                   accessibilityDescription: "MihomoBar")
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 状态变化立刻反映到菜单栏图标，不依赖 2 秒轮询
        model.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        model.startPolling()
        updateIcon()
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

    @objc private func contextToggleKernel() {
        Task { await model.toggleKernel() }
    }

    @objc private func contextOpenDashboard() {
        model.openDashboard()
    }

    @objc private func contextQuit() {
        NSApp.terminate(nil)
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
