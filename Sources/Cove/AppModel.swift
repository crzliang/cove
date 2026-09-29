import Foundation
import SwiftUI
import AppKit
import HelperProtocol

/// 应用唯一的共享状态中心。
///
/// 刻意不使用 `@State`：仅安装 Command Line Tools 时 SwiftUI 的宏插件
/// （`SwiftUIMacros` / `PreviewsMacros`）不存在，`@State` 与 `#Preview` 无法编译。
/// `@StateObject` + `ObservableObject` 不受影响，且两种环境下行为一致。
@MainActor
final class AppModel: ObservableObject {

    /// 主窗口侧边栏的导航项。
    /// 因为不能用 `@State`（CLT 下 SwiftUI 宏插件缺失），选择状态放在这里。
    enum SidebarItem: String, CaseIterable, Identifiable {
        case overview, proxies, connections, rules, subscription, logs, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview:     return "概览"
            case .proxies:      return "节点"
            case .connections:  return "连接"
            case .rules:        return "规则"
            case .subscription: return "订阅"
            case .logs:         return "日志"
            case .settings:     return "设置"
            }
        }

        var symbol: String {
            switch self {
            case .overview:     return "gauge.medium"
            case .proxies:      return "globe"
            case .connections:  return "arrow.left.arrow.right"
            case .rules:        return "list.bullet.rectangle"
            case .subscription: return "arrow.triangle.2.circlepath"
            case .logs:         return "text.alignleft"
            case .settings:     return "gearshape"
            }
        }
    }

    struct GroupInfo: Identifiable {
        let id: String
        let name: String
        let now: String
        let options: [String]
        let delay: Int?
    }

    @Published private(set) var status: Kernel.Status = .stopped
    /// 解析后的内核版本；解析失败时为 nil，此时退回显示 `versionLine` 原文
    @Published private(set) var kernelVersion: KernelVersion?
    /// 内核 `-v` 的原始输出（兜底用）
    @Published private(set) var versionLine: String = "—"
    @Published private(set) var groups: [GroupInfo] = []
    @Published private(set) var mode: String = "rule"
    @Published private(set) var systemProxyOn: Bool = false
    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var providerInfo: String?
    @Published private(set) var busy: Bool = false
    @Published private(set) var helperInstalled = false
    @Published private(set) var helperRunning = false

    // MARK: - 界面状态（同样因为不能用 @State）
    @Published var sidebarSelection: SidebarItem = .overview
    @Published var nodeSearch: String = ""
    @Published var selectedGroupID: String?
    /// 单节点延迟测试结果。比 /proxies 里带的 history 更新，用来做即时反馈。
    @Published private(set) var nodeDelays: [String: Int] = [:]
    @Published private(set) var testingDelays = false

    // MARK: - 连接
    @Published private(set) var connections: [CtlClient.Connection] = []
    @Published private(set) var connectionTotals: (up: Int, down: Int) = (0, 0)
    @Published private(set) var connectionMemory: Int = 0
    /// 经代理探测到的出口公网 IP；未探测或失败时为 nil。
    @Published private(set) var exitIP: String?
    @Published private(set) var exitIPRefreshing = false
    private var lastExitIPFetch: Date = .distantPast
    /// 单条连接的实时速率（字节/秒）。
    ///
    /// mihomo 的 /connections 只给**累计**字节，没有速率字段，
    /// 所以这里按两次轮询的差值自己算。
    struct Rate: Equatable {
        var up: Double = 0
        var down: Double = 0
    }

    @Published private(set) var connectionRates: [String: Rate] = [:]
    @Published var connectionSearch: String = "" {
        didSet { recomputeVisibleConnections() }
    }
    /// 连接列表默认按「最近有流量」排序，方便看正在传输的
    @Published var connectionSortByTraffic = true {
        didSet {
            if connectionSortByTraffic { connectionSortColumn = .traffic }
            recomputeVisibleConnections()
        }
    }
    /// 连接表头排序列
    enum ConnectionSortColumn: String {
        case host, rule, chains, traffic, duration
    }
    @Published var connectionSortColumn: ConnectionSortColumn = .traffic {
        didSet { recomputeVisibleConnections() }
    }
    @Published var connectionSortAscending = false {
        didSet { recomputeVisibleConnections() }
    }
    /// 筛选/排序后的可见列表（缓存，避免 SwiftUI 每次 body 重算）。
    @Published private(set) var visibleConnections: [CtlClient.Connection] = []
    /// 连接页选中行，右侧展示详情；nil 表示未选中。
    @Published var selectedConnectionID: String?

    /// 上一次采样，用于算速率
    private var previousSamples: [String: (up: Int, down: Int, at: Date)] = [:]

    // MARK: - 规则
    @Published private(set) var rules: [CtlClient.Rule] = []
    @Published var ruleSearch: String = ""
    @Published private(set) var visibleRules: [CtlClient.Rule] = []
    /// 规则页「添加」表单（不能用 @State）
    @Published var showingAddRuleSheet = false
    @Published var draftRuleType: String = "DOMAIN-SUFFIX"
    @Published var draftRulePayload: String = ""
    @Published var draftRuleProxy: String = "DIRECT"
    @Published var draftRuleNoResolve: Bool = false

    /// 节点页展开的策略组（卡片网格）
    @Published var expandedProxyGroups: Set<String> = []

    @Published var settings: Settings
    @Published var banner: Banner?

    /// 订阅页「添加」表单草稿（不能用 @State，见类型注释）
    @Published var draftSubName: String = ""
    @Published var draftSubURL: String = ""
    /// 正在编辑的订阅；nil 表示编辑表单关闭。
    @Published var editingSubscriptionID: String? = nil
    @Published var editSubName: String = ""
    @Published var editSubURL: String = ""
    /// 正在单独更新的订阅 id
    @Published private(set) var updatingSubscriptionID: String?

    /// 设置改过了但内核还在用旧的 —— 提示用户重启
    @Published var needsRestart: Bool = false

    /// 瞬态 UI 状态刻意放在这里而不是 `@State`，原因见类型注释。
    @Published var expandedGroup: String?
    @Published var showLog: Bool = false
    @Published var showSettings: Bool = false

    /// 日志页筛选（不能用 @State）
    @Published var logLevelFilter: String = "all"
    @Published var logCategoryFilter: String = "all"
    @Published var logSearch: String = ""
    /// 已解析的最近日志；文件没变就不重读。
    @Published private(set) var logEntries: [KernelLogEntry] = []
    private var logFileSize: UInt64 = 0
    private var logFileMTime: Date? = nil

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    let kernel = Kernel()
    let traffic = TrafficMonitor()

    /// 由 AppDelegate 注入：打开独立主窗口。
    /// 用回调而不是直接引用 AppDelegate，避免 AppModel 依赖 UI 层。
    var onOpenMainWindow: (() -> Void)?
    private var statusTimer: Timer?
    private var ctl: CtlClient? {
        guard let endpoint = kernel.endpoint else { return nil }
        return CtlClient(base: endpoint, secret: kernel.secret)
    }

    init() {
        settings = Settings.load()
        systemProxyOn = SystemProxy.isEnabled()
        launchAtLogin = LaunchAtLogin.isEnabled
        helperInstalled = HelperInstaller.isInstalled
        helperRunning = HelperInstaller.isRunning
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
            traffic.stop()
            kernel.stop()
            SystemDNS.restore()
            status = kernel.status
            groups = []
            providerInfo = nil
            exitIP = nil
            connectionMemory = 0
            needsRestart = false
            busy = false
            return
        }
        await startKernel()
    }

    func startKernel() async {
        let privileged = settings.tunEnabled

        // TUN 必须由 root 助手启动内核；没装助手就只能拒绝，
        // 而不是静默回退到用户态 —— 那样 TUN 不会生效但用户不知道
        if privileged && !HelperInstaller.isInstalled {
            let msg = "TUN 模式需要特权助手。请到设置里点「安装特权助手」后重试。"
            status = .failed(msg)
            banner = Banner(text: msg, isError: true)
            return
        }

        // 外层（如切换 TUN）已经占着 busy 时不要在这里清掉，否则概览会闪回空页。
        let acquiredBusy = !busy
        if acquiredBusy { busy = true }
        defer { if acquiredBusy { busy = false } }
        do {
            let binary = try Bundled.ensureKernel()

            // 有订阅但还没落盘时先拉一份，否则 type: file 的 provider 是空的
            if settings.customConfigPath.trimmingCharacters(in: .whitespaces).isEmpty {
                for sub in settings.activeSubscriptions {
                    let path = Paths.subscriptionFile(id: sub.id)
                    if !FileManager.default.fileExists(atPath: path.path) {
                        let result = try await SubscriptionFetcher.downloadAndStore(sub)
                        applySubscriptionFetch(result, id: sub.id)
                    }
                }
                try? settings.save()
            }

            let config = try ConfigWriter.resolvedConfig(for: settings)

            // 提权模式下配置文件由用户可写，而内核以 root 读它。
            // mihomo 会以 root 执行配置里的 post-up / post-down，必须先告知。
            if privileged, let risk = Self.privilegedConfigRisk(config) {
                banner = Banner(text: risk, isError: true)
                return
            }

            // 不再挂 -ext-ui：本应用是原生界面，不需要 MetaCubeXD 网页面板，
            // 否则内核每次启动都会检查/下载 UI 并打日志。
            await kernel.start(config: config,
                               binary: binary,
                               dataDir: Paths.dataDir,
                               uiDir: nil,
                               privileged: privileged)
            status = kernel.status
            if case .failed(let msg) = kernel.status {
                banner = Banner(text: msg, isError: true)
            } else {
                needsRestart = false
                if privileged {
                    SystemDNS.applyTunDNS()
                } else {
                    SystemDNS.restore()
                }
                await refreshRuntime()
                await refreshExitIP(force: true)
            }
        } catch {
            let msg = String(describing: error)
            status = .failed(msg)
            banner = Banner(text: msg, isError: true)
        }
    }

    /// 提权运行时，配置里的 `post-up` / `post-down` 会被内核以 root 身份执行。
    /// 生成的配置永远不会带这两项，但用户指定的自定义配置可能会。
    private static func privilegedConfigRisk(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let found = ["post-up:", "post-down:"].filter { text.contains($0) }
        guard !found.isEmpty else { return nil }
        return "配置中含 \(found.joined(separator: "、"))，TUN 模式下内核以 root 运行，"
             + "这些脚本会以 root 身份执行任意命令。请确认配置来源可信后再继续。"
    }

    // MARK: - 系统代理

    /// 开关 TUN：落盘 → 重写配置 → 按特权模式重启内核。
    ///
    /// 只改 `settings.tunEnabled` 不够——必须用助手以 root 拉起内核，
    /// TUN 接口才会真正建起来。
    func setTunEnabled(_ on: Bool) async {
        if on {
            helperInstalled = HelperInstaller.isInstalled
            helperRunning = HelperInstaller.isRunning
            guard helperInstalled else {
                banner = Banner(text: "TUN 需要特权助手。请到设置里先安装。", isError: true)
                sidebarSelection = .settings
                return
            }
            guard helperRunning else {
                banner = Banner(text: "特权助手未运行，请到设置重新安装助手。", isError: true)
                sidebarSelection = .settings
                return
            }
        }

        guard settings.tunEnabled != on else { return }

        var s = settings
        s.tunEnabled = on
        settings = s
        busy = true
        defer { busy = false }

        do {
            try s.save()
            if s.customConfigPath.trimmingCharacters(in: .whitespaces).isEmpty {
                _ = try ConfigWriter.resolvedConfig(for: s)
            }

            let wasRunning = kernel.status.isRunning
            if wasRunning {
                // 切换运行身份必须停掉旧进程再拉起
                if systemProxyOn {
                    try? SystemProxy.set(enabled: false, port: settings.mixedPort)
                    systemProxyOn = false
                }
                traffic.stop()
                status = .stopping
                await Task.yield()
                kernel.stop()
                SystemDNS.restore()
                status = kernel.status
                await Task.yield()
                // 给 utun / 端口一点释放时间
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            if wasRunning || on {
                status = .starting
                await Task.yield()
                await startKernel()
            }

            if case .failed(let msg) = status {
                banner = Banner(text: "TUN 切换失败：\(msg)", isError: true)
                return
            }

            needsRestart = false
            if on {
                let ok = kernel.isPrivileged && status.isRunning
                banner = Banner(
                    text: ok ? "TUN 已开启，内核以 root 运行" : "设置已保存，但内核未以特权模式运行",
                    isError: !ok)
            } else {
                banner = Banner(text: "TUN 已关闭", isError: false)
            }
            await refreshRuntime()
        } catch {
            banner = Banner(text: "切换 TUN 失败：\(error)", isError: true)
        }
    }

    func setSystemProxy(_ on: Bool) async {
        busy = true
        defer { busy = false }
        do {
            try SystemProxy.set(enabled: on, port: settings.mixedPort)
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
            await refreshExitIP(force: true)
        } catch {
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    func select(group: String, node: String) async {
        guard let ctl else { return }
        do {
            try await ctl.select(group: group, node: node)
            try await refreshProxies(using: ctl)
            await refreshExitIP(force: true)
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
            // 先写回磁盘，再让内核用空 path 重读启动时的 `-f` 文件
            _ = try ConfigWriter.resolvedConfig(for: settings)
            try await ctl.reloadConfig()
            banner = Banner(text: "已重载配置", isError: false)
            needsRestart = false
            await refreshRuntime()
        } catch {
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    /// 立即拉取订阅：系统网络下载 → 落盘 → 重载/刷新 provider。
    ///
    /// - Parameter id: 指定某一条；`nil` 表示更新全部启用中的订阅。
    func refreshSubscription(id: String? = nil) async {
        if !settings.customConfigPath.trimmingCharacters(in: .whitespaces).isEmpty {
            banner = Banner(text: "正在使用自定义配置，请在该文件里管理订阅", isError: true)
            return
        }
        let targets: [SubscriptionEntry]
        if let id {
            guard let one = settings.subscriptions.first(where: { $0.id == id }), one.isUsable else {
                banner = Banner(text: "找不到这条订阅", isError: true)
                return
            }
            targets = [one]
        } else {
            targets = settings.activeSubscriptions
            guard !targets.isEmpty else {
                banner = Banner(text: "还没有可用的订阅", isError: true)
                return
            }
        }

        busy = true
        defer { busy = false }
        do {
            var total = 0
            var errors: [String] = []
            var succeeded: [SubscriptionEntry] = []
            for sub in targets {
                do {
                    let result = try await SubscriptionFetcher.downloadAndStore(sub)
                    total += result.nodeCount
                    applySubscriptionFetch(result, id: sub.id)
                    if let updated = settings.subscriptions.first(where: { $0.id == sub.id }) {
                        succeeded.append(updated)
                    }
                } catch {
                    errors.append("\(sub.name)：\(error)")
                }
            }
            try settings.save()
            _ = try ConfigWriter.resolvedConfig(for: settings)

            let kernelRunning = ctl != nil
            if let ctl {
                // 策略组来自订阅 yaml，嵌在主配置里；节点在 provider 文件里。
                // 两边都可能变，必须先 reload 再 updateProvider。
                try await ctl.reloadConfig()
                try? await Task.sleep(nanoseconds: 500_000_000)
                for sub in succeeded {
                    try? await ctl.updateProvider(sub.providerName)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                needsRestart = false
                await refreshRuntime()
            }

            if errors.isEmpty {
                let msg = kernelRunning
                    ? "订阅已更新：共 \(total) 个节点"
                    : "订阅已下载（\(total) 个节点）。启动内核后生效。"
                banner = Banner(text: msg, isError: false)
            } else if total > 0 {
                banner = Banner(text: "部分成功（\(total) 节点）。失败：\(errors.joined(separator: "；"))",
                                isError: true)
            } else {
                banner = Banner(text: "订阅更新失败：\(errors.joined(separator: "；"))", isError: true)
            }
        } catch {
            banner = Banner(text: "订阅更新失败：\(String(describing: error))", isError: true)
        }
    }

    /// 添加一条订阅并立刻拉取。新订阅会成为唯一启用项。
    func addSubscription(name: String, url: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else {
            banner = Banner(text: "请填写订阅链接", isError: true)
            return
        }
        let entry = SubscriptionEntry.make(name: n.isEmpty ? "订阅 \(settings.subscriptions.count + 1)" : n,
                                           url: u)
        for i in settings.subscriptions.indices {
            settings.subscriptions[i].enabled = false
        }
        settings.subscriptions.append(entry)
        draftSubName = ""
        draftSubURL = ""
        do {
            try settings.save()
        } catch {
            banner = Banner(text: "保存失败：\(error)", isError: true)
            return
        }
        await refreshSubscription(id: entry.id)
    }

    func removeSubscription(id: String) {
        let wasEnabled = settings.subscriptions.first(where: { $0.id == id })?.enabled == true
        settings.subscriptions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Paths.subscriptionFile(id: id))
        if editingSubscriptionID == id {
            cancelEditSubscription()
        }
        // 删掉当前启用项时，自动启用剩下的第一条，避免节点页空着却不知道为什么。
        if wasEnabled, let first = settings.subscriptions.firstIndex(where: { !$0.trimmedURL.isEmpty }) {
            for i in settings.subscriptions.indices {
                settings.subscriptions[i].enabled = (i == first)
            }
        }
        Task { await applySubscriptionSelection(successText: "订阅已删除") }
    }

    func beginEditSubscription(id: String) {
        guard let sub = settings.subscriptions.first(where: { $0.id == id }) else { return }
        editingSubscriptionID = id
        editSubName = sub.name
        editSubURL = sub.url
    }

    func cancelEditSubscription() {
        editingSubscriptionID = nil
        editSubName = ""
        editSubURL = ""
    }

    /// 保存名称 / 链接。链接变了会立刻重新拉取。
    func saveEditSubscription() async {
        guard let id = editingSubscriptionID,
              let idx = settings.subscriptions.firstIndex(where: { $0.id == id }) else {
            cancelEditSubscription()
            return
        }
        let name = editSubName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = editSubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            banner = Banner(text: "请填写订阅链接", isError: true)
            return
        }

        let urlChanged = settings.subscriptions[idx].trimmedURL != url
        settings.subscriptions[idx].name = name.isEmpty
            ? (URL(string: url)?.host ?? "订阅 \(idx + 1)")
            : name
        settings.subscriptions[idx].url = url
        if urlChanged {
            settings.subscriptions[idx].lastNodeCount = nil
            settings.subscriptions[idx].updatedAt = nil
            settings.subscriptions[idx].trafficUpload = nil
            settings.subscriptions[idx].trafficDownload = nil
            settings.subscriptions[idx].trafficTotal = nil
        }
        cancelEditSubscription()
        do {
            try settings.save()
        } catch {
            banner = Banner(text: "保存失败：\(error)", isError: true)
            return
        }

        if urlChanged, settings.subscriptions[idx].isUsable {
            await refreshSubscriptionRow(id: id)
        } else if settings.subscriptions[idx].enabled {
            await applySubscriptionSelection(successText: "订阅已保存")
        } else {
            banner = Banner(text: "订阅已保存", isError: false)
        }
    }

    /// 只启用这一条，关掉其它；写配置并刷新节点。
    func activateSubscription(id: String) async {
        guard let idx = settings.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let name = settings.subscriptions[idx].name
        var changed = false
        for i in settings.subscriptions.indices {
            let on = (i == idx)
            if settings.subscriptions[i].enabled != on {
                settings.subscriptions[i].enabled = on
                changed = true
            }
        }
        guard changed else { return }

        let file = Paths.subscriptionFile(id: id)
        if !FileManager.default.fileExists(atPath: file.path) {
            do { try settings.save() } catch {
                banner = Banner(text: "保存失败：\(error)", isError: true)
                return
            }
            await refreshSubscription(id: id)
            return
        }
        await applySubscriptionSelection(successText: "已切换到「\(name)」")
    }

    func setSubscriptionEnabled(id: String, enabled: Bool) async {
        if enabled {
            await activateSubscription(id: id)
            return
        }
        guard let idx = settings.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        guard settings.subscriptions[idx].enabled else { return }
        settings.subscriptions[idx].enabled = false
        await applySubscriptionSelection(successText: "已停用「\(settings.subscriptions[idx].name)」")
    }

    /// 按当前启用列表重写配置；内核在跑就热重载并刷节点。
    private func applySubscriptionSelection(successText: String) async {
        busy = true
        defer { busy = false }
        do {
            try settings.save()
            if settings.customConfigPath.trimmingCharacters(in: .whitespaces).isEmpty {
                _ = try ConfigWriter.resolvedConfig(for: settings)
            }
            if let ctl {
                // 策略组随订阅变，必须整份重载，不能只 updateProvider。
                try await ctl.reloadConfig()
                try? await Task.sleep(nanoseconds: 500_000_000)
                for sub in settings.activeSubscriptions {
                    try? await ctl.updateProvider(sub.providerName)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                needsRestart = false
                await refreshRuntime()
            }
            banner = Banner(text: successText, isError: false)
        } catch {
            banner = Banner(text: "切换订阅失败：\(error)", isError: true)
        }
    }

    private func applySubscriptionFetch(_ result: SubscriptionFetcher.Result, id: String) {
        guard let idx = settings.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        settings.subscriptions[idx].lastNodeCount = result.nodeCount
        settings.subscriptions[idx].updatedAt = Date()
        if result.upload != nil || result.download != nil || result.total != nil {
            settings.subscriptions[idx].trafficUpload = result.upload
            settings.subscriptions[idx].trafficDownload = result.download
            settings.subscriptions[idx].trafficTotal = result.total
        }
    }

    func refreshSubscriptionRow(id: String) async {
        updatingSubscriptionID = id
        defer { updatingSubscriptionID = nil }
        await refreshSubscription(id: id)
    }

    /// 测一组节点的延迟。交给内核并发跑，比在客户端逐个发请求快得多。
    func testDelays(group: String, all: Bool = true) async {
        guard let ctl, let info = groups.first(where: { $0.id == group }) else { return }
        testingDelays = true
        defer { testingDelays = false }

        let targets = all ? info.options : [info.now]
        await withTaskGroup(of: (String, Int?).self) { taskGroup in
            for name in targets.prefix(200) {
                taskGroup.addTask {
                    let value = try? await ctl.delay(node: name)
                    return (name, value)
                }
            }
            for await (name, value) in taskGroup {
                if let value { nodeDelays[name] = value }
            }
        }
        try? await refreshProxies(using: ctl)
    }

    func testSingleDelay(_ node: String) async {
        guard let ctl else { return }
        if let value = try? await ctl.delay(node: node) {
            nodeDelays[node] = value
        }
    }

    /// 把某个策略组切换后的完整节点信息交给界面
    func group(by id: String) -> GroupInfo? {
        groups.first { $0.id == id }
    }

    var currentGroup: GroupInfo? {
        group(by: selectedGroupID ?? "") ?? groups.first
    }

    // MARK: - 连接

    /// 拉取一次连接快照。可见时由轮询调用，也可以手动触发。
    func refreshConnections() async {
        guard let ctl else { connections = []; return }
        await refreshConnections(using: ctl)
    }

    private func refreshConnections(using ctl: CtlClient) async {
        do {
            let snap = try await ctl.connections()
            let list = snap.connections ?? []
            connections = list
            connectionTotals = (snap.uploadTotal, snap.downloadTotal)
            // API 有时恒为 0（本机构建实测 /connections.memory 与 /memory inuse 皆 0），
            // 回退到内核进程 RSS，与活动监视器一致。
            if let api = snap.memory, api > 0 {
                connectionMemory = api
            } else if let pid = kernel.runningPID,
                      let rss = Privileged.residentBytes(of: pid) {
                connectionMemory = rss
            } else {
                connectionMemory = 0
            }
            updateRates(list)
            recomputeVisibleConnections()
            if let id = selectedConnectionID, !list.contains(where: { $0.id == id }) {
                selectedConnectionID = nil
            }
        } catch {
            // 内核刚重启时接口可能还没就绪，静默跳过
        }
    }

    /// 用相邻两次采样的字节差算速率
    private func updateRates(_ list: [CtlClient.Connection]) {
        let now = Date()
        var rates: [String: Rate] = [:]

        for conn in list {
            if let prev = previousSamples[conn.id] {
                let dt = now.timeIntervalSince(prev.at)
                // 间隔太短会让差值噪声放大；间隔太长说明中间漏了采样
                if dt > 0.3 && dt < 30 {
                    rates[conn.id] = Rate(
                        up: Double(max(0, conn.upload - prev.up)) / dt,
                        down: Double(max(0, conn.download - prev.down)) / dt)
                }
            }
        }

        // 已经消失的连接要清掉，否则字典会无限增长
        var next: [String: (up: Int, down: Int, at: Date)] = [:]
        for conn in list {
            next[conn.id] = (conn.upload, conn.download, now)
        }
        previousSamples = next
        connectionRates = rates
    }

    func rate(for conn: CtlClient.Connection) -> Rate? {
        connectionRates[conn.id]
    }

    func closeConnection(_ id: String) async {
        guard let ctl else { return }
        do {
            try await ctl.closeConnection(id)
            connections.removeAll { $0.id == id }
            if selectedConnectionID == id { selectedConnectionID = nil }
            recomputeVisibleConnections()
        } catch {
            banner = Banner(text: "断开连接失败：\(String(describing: error))", isError: true)
        }
    }

    func closeAllConnections() async {
        guard let ctl else { return }
        do {
            try await ctl.closeAllConnections()
            connections = []
            connectionRates = [:]
            previousSamples = [:]
            visibleConnections = []
            selectedConnectionID = nil
            banner = Banner(text: "已断开全部连接", isError: false)
        } catch {
            banner = Banner(text: "断开失败：\(String(describing: error))", isError: true)
        }
    }

    /// 按搜索词和排序偏好整理后的连接列表。
    ///
    /// 搜索的字段拼装刻意写成显式语句而不是 `[a,b,c].compactMap{...}` ——
    /// 后者会让类型检查器直接超时（Swift 对长链式 Optional 表达式很敏感）。
    private func recomputeVisibleConnections() {
        let keyword = connectionSearch.trimmingCharacters(in: .whitespaces).lowercased()
        var list = connections

        if !keyword.isEmpty {
            list = connections.filter { conn in
                let m = conn.metadata
                var parts: [String] = []
                parts.append(m?.host ?? "")
                parts.append(m?.sniffHost ?? "")
                parts.append(m?.destinationIP ?? "")
                parts.append(m?.sourceIP ?? "")
                parts.append(m?.destinationPort?.value ?? "")
                parts.append(m?.sourcePort?.value ?? "")
                parts.append(m?.process ?? "")
                parts.append(m?.processPath ?? "")
                parts.append(conn.rule ?? "")
                parts.append(conn.rulePayload ?? "")
                return parts.joined(separator: " ").lowercased().contains(keyword)
            }
        }

        let ascending = connectionSortAscending
        list.sort { a, b in
            let result: Bool
            switch connectionSortColumn {
            case .host:
                result = connectionHost(a).localizedCaseInsensitiveCompare(connectionHost(b)) == .orderedAscending
            case .rule:
                let ra = "\(a.rule ?? ""),\(a.rulePayload ?? "")"
                let rb = "\(b.rule ?? ""),\(b.rulePayload ?? "")"
                result = ra.localizedCaseInsensitiveCompare(rb) == .orderedAscending
            case .chains:
                let ca = (a.chains ?? []).reversed().joined(separator: " → ")
                let cb = (b.chains ?? []).reversed().joined(separator: " → ")
                result = ca.localizedCaseInsensitiveCompare(cb) == .orderedAscending
            case .traffic:
                result = (a.upload + a.download) < (b.upload + b.download)
            case .duration:
                let da = a.startDate ?? .distantPast
                let db = b.startDate ?? .distantPast
                result = da < db
            }
            return ascending ? result : !result
        }
        visibleConnections = list
    }

    private func connectionHost(_ conn: CtlClient.Connection) -> String {
        let m = conn.metadata
        if let host = m?.host, !host.isEmpty { return host }
        if let sniff = m?.sniffHost, !sniff.isEmpty { return sniff }
        if let ip = m?.destinationIP, !ip.isEmpty { return ip }
        return conn.rulePayload ?? ""
    }

    func toggleConnectionSort(_ column: ConnectionSortColumn) {
        if connectionSortColumn == column {
            connectionSortAscending.toggle()
        } else {
            connectionSortColumn = column
            connectionSortAscending = (column == .host || column == .rule || column == .chains)
        }
        connectionSortByTraffic = (column == .traffic && !connectionSortAscending)
    }

    // MARK: - 规则

    func refreshRules() async {
        guard let ctl else { rules = []; visibleRules = []; return }
        do {
            rules = try await ctl.rules()
            recomputeVisibleRules()
        } catch {
            // 静默
        }
    }

    private func recomputeVisibleRules() {
        let keyword = ruleSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else {
            visibleRules = rules
            return
        }
        visibleRules = rules.filter { rule in
            [rule.type, rule.payload ?? "", rule.proxy ?? ""]
                .joined(separator: " ")
                .lowercased()
                .contains(keyword)
        }
    }

    func updateRuleSearch(_ text: String) {
        ruleSearch = text
        recomputeVisibleRules()
    }

    /// 可选出站：内置 + 当前策略组。
    var ruleProxyOptions: [String] {
        var opts = ["DIRECT", "REJECT", "🚀 节点选择", "♻️ 自动选择", "PROXY"]
        for g in groups where !opts.contains(g.name) {
            opts.append(g.name)
        }
        return opts
    }

    var canEditCustomRules: Bool {
        settings.customConfigPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func addCustomRule(_ rule: CustomRule) async {
        guard canEditCustomRules else {
            banner = Banner(text: "正在使用自定义配置，请直接编辑该 YAML 的 rules", isError: true)
            return
        }
        guard rule.clashLine != nil else {
            banner = Banner(text: "规则不完整：请填写类型、内容和出站", isError: true)
            return
        }
        var s = settings
        s.customRules.insert(rule, at: 0)
        await persistCustomRules(s, message: "已添加规则")
        resetRuleDraft()
        showingAddRuleSheet = false
    }

    func beginAddCustomRule() {
        resetRuleDraft()
        if !ruleProxyOptions.contains(draftRuleProxy) {
            draftRuleProxy = ruleProxyOptions.first ?? "DIRECT"
        }
        showingAddRuleSheet = true
    }

    func resetRuleDraft() {
        draftRuleType = "DOMAIN-SUFFIX"
        draftRulePayload = ""
        draftRuleProxy = "DIRECT"
        draftRuleNoResolve = false
    }

    func submitDraftCustomRule() async {
        let rule = CustomRule.make(type: draftRuleType,
                                   payload: draftRulePayload,
                                   proxy: draftRuleProxy,
                                   noResolve: draftRuleNoResolve)
        await addCustomRule(rule)
    }

    func deleteCustomRule(id: String) async {
        guard canEditCustomRules else { return }
        var s = settings
        s.customRules.removeAll { $0.id == id }
        await persistCustomRules(s, message: "已删除规则")
    }

    func toggleCustomRule(id: String) async {
        guard canEditCustomRules else { return }
        var s = settings
        guard let idx = s.customRules.firstIndex(where: { $0.id == id }) else { return }
        s.customRules[idx].enabled.toggle()
        await persistCustomRules(s, message: s.customRules[idx].enabled ? "已启用规则" : "已禁用规则")
    }

    private func persistCustomRules(_ s: Settings, message: String) async {
        settings = s
        do {
            try s.save()
            _ = try ConfigWriter.resolvedConfig(for: s)
            if status.isRunning {
                if let ctl {
                    try await ctl.reloadConfig()
                    await refreshRules()
                    banner = Banner(text: "\(message)，已重载内核", isError: false)
                } else {
                    needsRestart = true
                    banner = Banner(text: "\(message)。请重启内核生效", isError: false)
                }
            } else {
                banner = Banner(text: message, isError: false)
            }
        } catch {
            banner = Banner(text: "保存规则失败：\(error)", isError: true)
        }
    }

    func toggleProxyGroupExpanded(_ id: String) {
        if expandedProxyGroups.contains(id) {
            expandedProxyGroups.remove(id)
        } else {
            expandedProxyGroups.insert(id)
        }
    }

    // MARK: - 登录项

    func setLaunchAtLogin(_ enabled: Bool) async {
        do {
            try LaunchAtLogin.set(enabled)
            launchAtLogin = LaunchAtLogin.isEnabled

            // 开机自启时自动开窗会很打扰，顺手关掉（用户随时可以再打开）
            var note = ""
            if launchAtLogin && settings.showWindowOnLaunch {
                settings.showWindowOnLaunch = false
                try? settings.save()
                note = "，并已关闭「启动时打开窗口」以免开机时打扰"
            }
            banner = Banner(text: launchAtLogin ? "已设置为开机自启\(note)" : "已取消开机自启",
                            isError: false)
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    // MARK: - 特权助手

    /// 安装助手。**整个应用只在这里弹一次授权框**（支持触控 ID）。
    /// 装完之后 TUN 与系统代理都走 socket，不再有任何弹框。
    func installHelper() async {
        busy = true
        defer { busy = false }
        do {
            // 授权框必须在主线程弹出，否则可能变成不可指纹的降级路径或直接失败。
            try await MainActor.run {
                _ = try HelperInstaller.install()
            }
            helperInstalled = HelperInstaller.isInstalled
            helperRunning = HelperInstaller.isRunning
            banner = Banner(text: "特权助手已安装。之后开关 TUN 和系统代理都不会再弹授权框。",
                            isError: false)
        } catch {
            helperInstalled = HelperInstaller.isInstalled
            helperRunning = HelperInstaller.isRunning
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    func uninstallHelper() async {
        if kernel.status.isRunning && kernel.isPrivileged {
            banner = Banner(text: "内核正以 root 运行，请先停止内核再卸载助手", isError: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await MainActor.run {
                try HelperInstaller.uninstall()
            }
            helperInstalled = HelperInstaller.isInstalled
            helperRunning = false
            banner = Banner(text: "助手已卸载，特权操作会退回为每次弹授权框", isError: false)
        } catch {
            banner = Banner(text: String(describing: error), isError: true)
        }
    }

    // MARK: - 设置

    func saveSettings(_ s: Settings) {
        let runtimeKeysChanged =
            s.mixedPort != settings.mixedPort ||
            s.subscriptions != settings.subscriptions ||
            s.customRules != settings.customRules ||
            s.customConfigPath != settings.customConfigPath ||
            s.tunEnabled != settings.tunEnabled ||
            s.logLevel != settings.logLevel

        settings = s
        do {
            try s.save()
            // 订阅等改动立刻写回 generated.yaml，避免「设置已保存但磁盘配置还是旧的」
            // 导致「立即更新」去刷一个不存在的 provider → 404。
            if runtimeKeysChanged, s.customConfigPath.trimmingCharacters(in: .whitespaces).isEmpty {
                _ = try ConfigWriter.resolvedConfig(for: s)
            }
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
            kernelVersion = nil
            return
        }
        versionLine = line
        kernelVersion = KernelVersion.parse(line)
    }

    /// 概览页副标题。
    ///
    /// 只放「哪个内核 + 版本号」—— 平台、Go 版本、构建时间、编译标签都在设置页。
    /// 之前把 `mihomo -v` 的原始两行直接铺上去，是 88 字符的一整行，
    /// 实测横跨窗口 44% 宽度，副标题位置完全读不了。
    var versionSummary: String {
        kernelVersion?.short ?? versionLine
    }

    var logTail: String { kernel.tailLog(lines: 200) }

    var visibleLogEntries: [KernelLogEntry] {
        var matched: [KernelLogEntry] = []
        matched.reserveCapacity(min(logEntries.count, 200))
        for entry in logEntries where KernelLogFilter.matches(
            entry,
            level: logLevelFilter,
            category: logCategoryFilter,
            search: logSearch)
        {
            matched.append(entry)
        }
        return matched.reversed()
    }

    /// 仅供 --dump-menu / --selftest 这类 headless 场景使用：
    /// 直接绕过轮询，把内核状态同步到界面状态。
    func syncStatusFromKernel() {
        status = kernel.status
        if kernel.status.isRunning, let endpoint = kernel.endpoint {
            traffic.start(base: endpoint, secret: kernel.secret)
        }
    }

    func refreshLog(force: Bool = false) {
        let url = Paths.kernelLog
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs?[.modificationDate] as? Date
        if !force,
           size == logFileSize,
           mtime == logFileMTime,
           !logEntries.isEmpty || size == 0 {
            return
        }
        logFileSize = size
        logFileMTime = mtime
        let text = kernel.tailLog(lines: 200)
        logEntries = text.isEmpty ? [] : KernelLogEntry.parseLines(text)
    }

    // MARK: - 轮询

    private func refreshRuntime() async {
        // 提权内核没有 terminationHandler，靠这里发现它已经死了
        kernel.refreshLiveness()
        if kernel.status != status { status = kernel.status }

        // 内核异常退出时也要收回 DNS，避免一直指着 198.18.0.1
        if !kernel.status.isRunning {
            SystemDNS.restore()
        }

        systemProxyOn = SystemProxy.isEnabled()
        launchAtLogin = LaunchAtLogin.isEnabled
        helperInstalled = HelperInstaller.isInstalled
        helperRunning = HelperInstaller.isRunning

        if sidebarSelection == .logs {
            refreshLog()
        }

        // 内核起来就接上流量流；停了或换端口/密钥时必须重连（见 TrafficMonitor.start）。
        if let endpoint = kernel.endpoint {
            traffic.start(base: endpoint, secret: kernel.secret)
        } else {
            traffic.stop()
        }

        guard let ctl else {
            groups = []
            providerInfo = nil
            exitIP = nil
            return
        }
        do {
            // 连接 / 规则只在对应页可见时拉，避免无谓的大 JSON。
            if sidebarSelection == .connections {
                let cfg = try await ctl.configs()
                if let m = cfg.mode { mode = m }
                await refreshConnections(using: ctl)
                return
            }
            if sidebarSelection == .rules {
                let cfg = try await ctl.configs()
                if let m = cfg.mode { mode = m }
                do { rules = try await ctl.rules(); recomputeVisibleRules() } catch {}
                return
            }

            let cfg = try await ctl.configs()
            if let m = cfg.mode { mode = m }
            try await refreshProxies(using: ctl)
            await refreshProviderInfo(using: ctl)
            if sidebarSelection == .overview {
                await refreshConnections(using: ctl)
                await refreshExitIPIfNeeded()
            }
        } catch {
            // 内核刚起来时 API 可能还没就绪，静默忽略，下个周期重试
        }
    }

    /// 经 mixed-port 访问公网 IP 接口，得到当前出口地址。
    func refreshExitIP(force: Bool = true) async {
        await refreshExitIPIfNeeded(force: force)
    }

    private func refreshExitIPIfNeeded(force: Bool = false) async {
        guard status.isRunning else {
            exitIP = nil
            exitIPRefreshing = false
            return
        }
        if !force, Date().timeIntervalSince(lastExitIPFetch) < 45 { return }
        if exitIPRefreshing { return }
        exitIPRefreshing = true
        defer { exitIPRefreshing = false }
        lastExitIPFetch = Date()

        let port = settings.mixedPort
        let endpoints = [
            "https://api.ipify.org",
            "https://ifconfig.me/ip",
            "https://api.ip.sb/ip",
        ]
        for urlString in endpoints {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.setValue("Cove", forHTTPHeaderField: "User-Agent")

            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: "127.0.0.1",
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort: port,
            ]
            let session = URLSession(configuration: config)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      text.count <= 45,
                      !text.contains("<") else { continue }
                exitIP = text
                return
            } catch {
                continue
            }
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
        let active = settings.activeSubscriptions
        guard !active.isEmpty, settings.customConfigPath.isEmpty else {
            providerInfo = nil
            return
        }
        guard let providers = try? await ctl.providers() else {
            providerInfo = "订阅尚未加载"
            return
        }
        var total = 0
        var loaded = 0
        for sub in active {
            if let entry = providers[sub.providerName] {
                total += entry.nodeCount
                loaded += 1
                if let idx = settings.subscriptions.firstIndex(where: { $0.id == sub.id }) {
                    settings.subscriptions[idx].lastNodeCount = entry.nodeCount
                }
            }
        }
        if loaded == 0 {
            providerInfo = "订阅尚未加载"
        } else if active.count == 1 {
            providerInfo = "\(total) 个节点"
        } else {
            providerInfo = "\(active.count) 个订阅 · 共 \(total) 个节点"
        }
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
