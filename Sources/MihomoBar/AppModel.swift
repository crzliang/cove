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
    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var providerInfo: String?
    @Published private(set) var busy: Bool = false

    @Published var settings: Settings
    @Published var banner: Banner?

    /// 设置改过了但内核还在用旧的 —— 提示用户重启
    @Published var needsRestart: Bool = false

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
        launchAtLogin = LaunchAtLogin.isEnabled
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

    // MARK: - 内核

    func toggleKernel() async {
        if kernel.status.isRunning {
            busy = true
            if systemProxyOn { await setSystemProxy(false) }
            kernel.stop()
            status = kernel.status
            groups = []
            providerInfo = nil
            needsRestart = false
            busy = false
            return
        }
        await startKernel()
    }

    func startKernel() async {
        busy = true
        defer { busy = false }
        do {
            let binary = try Bundled.ensureKernel()
            let ui = try Bundled.ensureUI()
            let config = try ConfigWriter.resolvedConfig(for: settings)

            // TUN 必须 root：接口创建、路由改写都在内核内部做
            let privileged = settings.tunEnabled

            await kernel.start(config: config,
                               binary: binary,
                               dataDir: Paths.dataDir,
                               uiDir: ui,
                               privileged: privileged)
            status = kernel.status
            if case .failed(let msg) = kernel.status {
                banner = Banner(text: msg, isError: true)
            } else {
                needsRestart = false
                await refreshRuntime()
                if privileged {
                    banner = Banner(text: "内核已以 root 运行（TUN 模式）。提权进程不随本应用退出，退出后请用「停止内核」收尾。",
                                    isError: false)
                }
            }
        } catch {
            let msg = String(describing: error)
            status = .failed(msg)
            banner = Banner(text: msg, isError: true)
        }
    }

    // MARK: - 系统代理

    func setSystemProxy(_ on: Bool) async {
        busy = true
        defer { busy = false }
        do {
            if on {
                try SystemProxy.enable(port: settings.mixedPort)
            } else {
                try SystemProxy.disable()
            }
            systemProxyOn = on
            banner = Banner(text: on ? "系统代理已开启 → 127.0.0.1:\(settings.mixedPort)" : "系统代理已关闭",
                            isError: false)
        } catch {
            systemProxyOn = SystemProxy.isEnabled()
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    // MARK: - 内核控制

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
            try await refreshProxies(using: ctl)
        } catch {
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    func reloadConfig() async {
        guard let ctl else {
            banner = Banner(text: "内核未运行", isError: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            if settings.customConfigPath.isEmpty {
                // 设置可能改过（端口、订阅），先重新生成
                _ = try ConfigWriter.resolvedConfig(for: settings)
            }
            try await ctl.reloadConfig()
            banner = Banner(text: "已重载配置", isError: false)
            needsRestart = false
            await refreshRuntime()
        } catch {
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    /// 立即拉取订阅。平时用不到 —— 内核配了 `interval` 会自己定时刷新。
    func refreshSubscription() async {
        guard let ctl else {
            banner = Banner(text: "内核未运行", isError: true)
            return
        }
        guard !settings.subscriptionURL.isEmpty else {
            banner = Banner(text: "还没有填写订阅链接", isError: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await ctl.updateProvider(ConfigWriter.providerName)
            // provider 更新后策略组列表会变，等一小会再刷新
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refreshRuntime()
            banner = Banner(text: "订阅已更新：\(providerInfo ?? "完成")", isError: false)
        } catch {
            banner = Banner(text: "订阅更新失败：\(String(describing: error))", isError: true)
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

    // MARK: - 登录项

    func setLaunchAtLogin(_ enabled: Bool) async {
        do {
            try LaunchAtLogin.set(enabled)
            launchAtLogin = LaunchAtLogin.isEnabled
            banner = Banner(text: launchAtLogin ? "已设置为开机自启" : "已取消开机自启",
                            isError: false)
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    // MARK: - 设置

    func saveSettings(_ s: Settings) {
        let runtimeKeysChanged =
            s.mixedPort != settings.mixedPort ||
            s.subscriptionURL != settings.subscriptionURL ||
            s.customConfigPath != settings.customConfigPath ||
            s.tunEnabled != settings.tunEnabled ||
            s.logLevel != settings.logLevel

        settings = s
        do {
            try s.save()
            if kernel.status.isRunning && runtimeKeysChanged {
                needsRestart = true
                banner = Banner(text: "设置已保存。这些改动需要重启内核才生效。", isError: false)
            } else {
                banner = Banner(text: "设置已保存", isError: false)
            }
        } catch {
            banner = Banner(text: "保存失败：\(String(describing: error))", isError: true)
        }
    }

    func revealDataDir() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.root.path)
    }

    func loadKernelVersion() {
        guard let binary = try? Bundled.ensureKernel(),
              let line = Bundled.kernelVersion(binary: binary) else {
            versionLine = BundledError.kernelMissing.description
            return
        }
        versionLine = line
    }

    var logTail: String { kernel.tailLog(lines: 120) }

    func refreshLog() {
        objectWillChange.send()
    }

    // MARK: - 轮询

    private func refreshRuntime() async {
        // 提权内核没有 terminationHandler，靠这里发现它已经死了
        kernel.refreshLiveness()
        if kernel.status != status { status = kernel.status }

        systemProxyOn = SystemProxy.isEnabled()
        launchAtLogin = LaunchAtLogin.isEnabled

        guard let ctl else {
            groups = []
            providerInfo = nil
            return
        }
        do {
            let cfg = try await ctl.configs()
            if let m = cfg.mode { mode = m }
            try await refreshProxies(using: ctl)
            await refreshProviderInfo(using: ctl)
        } catch {
            // 内核刚起来时 API 可能还没就绪，静默忽略，下个周期重试
        }
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

    private func refreshProviderInfo(using ctl: CtlClient) async {
        guard !settings.subscriptionURL.isEmpty, settings.customConfigPath.isEmpty else {
            providerInfo = nil
            return
        }
        guard let providers = try? await ctl.providers(),
              let sub = providers[ConfigWriter.providerName] else {
            providerInfo = "订阅尚未加载"
            return
        }
        var text = "\(sub.nodeCount) 个节点"
        if let updated = sub.updatedAt {
            text += " · 更新于 \(Self.shortTime(updated))"
        }
        providerInfo = text
    }

    private static func shortTime(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return iso }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}
