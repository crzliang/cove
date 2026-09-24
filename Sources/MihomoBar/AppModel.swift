import Foundation
import SwiftUI
import AppKit

/// 应用唯一的共享状态中心。
///
/// 刻意不使用 `@State`：仅安装 Command Line Tools 时 SwiftUI 的宏插件
/// （`SwiftUIMacros` / `PreviewsMacros`）不存在，`@State` 与 `#Preview` 无法编译。
/// `@StateObject` + `ObservableObject` 不受影响，且两种环境下行为一致。
@MainActor
final class AppModel: ObservableObject {

    struct GroupInfo: Identifiable {
        let id: String
        let name: String
        let now: String
        let options: [String]
        let delay: Int?
    }

    @Published private(set) var status: Kernel.Status = .stopped
    @Published private(set) var versionLine: String = "—"
    @Published private(set) var groups: [GroupInfo] = []
    @Published private(set) var mode: String = "rule"
    @Published private(set) var systemProxyOn: Bool = false
    @Published var settings: Settings
    @Published var banner: Banner?

    /// 瞬态 UI 状态刻意放在这里而不是 `@State`，原因见类型注释。
    @Published var expandedGroup: String?
    @Published var showLog: Bool = false
    @Published var showSettings: Bool = false

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    let kernel = Kernel()
    private var statusTimer: Timer?
    private var ctl: CtlClient? {
        guard let endpoint = kernel.endpoint else { return nil }
        return CtlClient(base: endpoint, secret: kernel.secret)
    }

    init() {
        settings = Settings.load()
        systemProxyOn = SystemProxy.isEnabled()
        status = kernel.status
        loadKernelVersion()
    }

    // MARK: - 生命周期

    func startPolling() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRuntime() }
        }
    }

    func stopPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    // MARK: - 操作

    func toggleKernel() async {
        if kernel.status.isRunning {
            kernel.stop()
            status = kernel.status
            groups = []
            if systemProxyOn { await setSystemProxy(false) }
            return
        }

        do {
            let binary = try Bundled.ensureKernel()
            let ui = try Bundled.ensureUI()
            let config = try ConfigWriter.resolvedConfig(for: settings)
            await kernel.start(config: config, binary: binary, dataDir: Paths.dataDir, uiDir: ui)
            status = kernel.status
            if case .failed(let msg) = kernel.status {
                banner = Banner(text: msg, isError: true)
            } else {
                await refreshRuntime()
                if settings.tunEnabled {
                    banner = Banner(text: "TUN 模式已启用，需管理员权限：请把内核以 root 运行，或在设置中改用系统代理。", isError: false)
                }
            }
        } catch {
            let msg = String(describing: error)
            status = .failed(msg)
            banner = Banner(text: msg, isError: true)
        }
    }

    func setSystemProxy(_ on: Bool) async {
        let port = settings.mixedPort
        do {
            if on {
                try SystemProxy.enable(port: port)
            } else {
                try SystemProxy.disable()
            }
            systemProxyOn = on
        } catch {
            systemProxyOn = SystemProxy.isEnabled()
            let msg = String(describing: error)
            banner = Banner(text: msg, isError: true)
        }
    }

    func setMode(_ newMode: String) async {
        guard let ctl else { return }
        do {
            try await ctl.setMode(newMode)
            mode = newMode
        } catch {
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    func select(group: String, node: String) async {
        guard let ctl else { return }
        do {
            try await ctl.select(group: group, node: node)
            await refreshProxies()
        } catch {
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    func testDelay(group: String) async {
        guard let ctl, let g = groups.first(where: { $0.id == group }) else { return }
        do {
            _ = try await ctl.delay(node: group)
            await refreshProxies()
            _ = g
        } catch {
            banner = Banner(text: "延迟测试失败：\(String(describing: error))", isError: true)
        }
    }

    func openDashboard() {
        guard kernel.endpoint != nil else {
            banner = Banner(text: "内核未运行", isError: true)
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(kernel.port)/ui/") else { return }
        NSWorkspace.shared.open(url)
    }

    func reloadConfig() async {
        guard let ctl else { return }
        do {
            try await ctl.reloadConfig()
            banner = Banner(text: "已重载配置", isError: false)
            await refreshRuntime()
        } catch {
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    func saveSettings(_ s: Settings) {
        settings = s
        do {
            try s.save()
            banner = Banner(text: "设置已保存" + (kernel.status.isRunning ? "，重启内核后生效" : ""), isError: false)
        } catch {
            banner = Banner(text: "保存失败：\(error)", isError: true)
        }
    }

    func loadKernelVersion() {
        guard let binary = try? Bundled.ensureKernel(),
              let line = Bundled.kernelVersion(binary: binary) else {
            versionLine = "内核缺失"
            return
        }
        versionLine = line
    }

    func revealDataDir() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.root.path)
    }

    var logTail: String { kernel.tailLog(lines: 120) }

    // MARK: - 轮询

    private func refreshRuntime() async {
        let newStatus = kernel.status
        if newStatus != status { status = newStatus }
        systemProxyOn = SystemProxy.isEnabled()

        guard let ctl else { groups = []; return }
        do {
            let cfg = try await ctl.configs()
            if let m = cfg.mode { mode = m }
            try await refreshProxies(using: ctl)
        } catch {
            // 内核刚起来时 API 可能还没就绪，静默忽略，下个周期重试
        }
    }

    private func refreshProxies() async {
        guard let ctl else { return }
        try? await refreshProxies(using: ctl)
    }

    private func refreshProxies(using ctl: CtlClient) async throws {
        let raw = try await ctl.proxies()
        let builtIn: Set<String> = ["GLOBAL", "DIRECT", "REJECT", "PASS", "COMPATIBLE", "REJECT-DROP"]
        let list: [GroupInfo] = raw.compactMap { key, value in
            guard value.isGroup, !builtIn.contains(key), let all = value.all else { return nil }
            let candidates = all.filter { name in
                guard let entry = raw[name] else { return true }
                return !["Direct", "Reject", "RejectDrop", "Compatible", "Pass"].contains(entry.type)
            }
            return GroupInfo(id: key,
                             name: key,
                             now: value.now ?? "—",
                             options: candidates,
                             delay: value.latestDelay)
        }
        .sorted { $0.name < $1.name }
        groups = list
    }
}
