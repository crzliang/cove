import SwiftUI

/// 主窗口：标准 macOS 应用布局 —— 工具栏 + 侧边栏 + 内容区 + 状态栏。
struct MainWindow: View {

    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
        }
        .toolbar { toolbarItems }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .alert(item: alertBinding) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message),
                  dismissButton: .default(Text("好")))
        }
    }

    /// 侧边栏选择状态放在 AppModel 里（不能用 @State，见 AppModel 顶部注释）
    private var selection: Binding<AppModel.SidebarItem?> {
        Binding(
            get: { model.sidebarSelection },
            set: { if let value = $0 { model.sidebarSelection = value } }
        )
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(selection: selection) {
            Section("状态") {
                Label("概览", systemImage: AppModel.SidebarItem.overview.symbol)
                    .tag(AppModel.SidebarItem.overview)
            }
            Section("代理") {
                Label("节点", systemImage: AppModel.SidebarItem.proxies.symbol)
                    .tag(AppModel.SidebarItem.proxies)
                Label("订阅", systemImage: AppModel.SidebarItem.subscription.symbol)
                    .tag(AppModel.SidebarItem.subscription)
            }
            Section("系统") {
                Label("日志", systemImage: AppModel.SidebarItem.logs.symbol)
                    .tag(AppModel.SidebarItem.logs)
                Label("设置", systemImage: AppModel.SidebarItem.settings.symbol)
                    .tag(AppModel.SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { sidebarBrand }
    }

    private var sidebarBrand: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("MihomoBar")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.status.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusDot(level: kernelLevel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 内容

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .overview:     OverviewPane(model: model)
        case .proxies:      ProxiesPane(model: model)
        case .subscription: SubscriptionPane(model: model)
        case .logs:         LogsPane(model: model)
        case .settings:     SettingsPane(model: model)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.toggleKernel() }
            } label: {
                Label(model.status.isRunning ? "停止" : "启动",
                      systemImage: model.status.isRunning ? "stop.fill" : "play.fill")
            }
            .disabled(model.status.isBusy || model.busy)
            .help(model.status.isRunning ? "停止内核" : "启动内核")
        }

        ToolbarItem(placement: .automatic) {
            Toggle(isOn: Binding(
                get: { model.systemProxyOn },
                set: { on in Task { await model.setSystemProxy(on) } })) {
                Label("系统代理", systemImage: "network")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.status.isRunning || model.busy)
            .help("系统代理 127.0.0.1:\(String(model.settings.mixedPort))")
        }

        ToolbarItem(placement: .automatic) {
            Picker("模式", selection: Binding(
                get: { model.mode },
                set: { m in Task { await model.setMode(m) } })) {
                Text("规则").tag("rule")
                Text("全局").tag("global")
                Text("直连").tag("direct")
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .disabled(!model.status.isRunning)
            .help("代理模式")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.openDashboard()
            } label: {
                Label("浏览器面板", systemImage: "safari")
            }
            .disabled(!model.status.isRunning)
            .help("在浏览器打开完整面板（规则、连接、流量曲线）")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.reloadConfig() }
            } label: {
                Label("重载配置", systemImage: "arrow.clockwise")
            }
            .disabled(!model.status.isRunning || model.busy)
            .help("让内核重新读取磁盘上的配置")
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                StatusDot(level: kernelLevel)
                Text(model.status.isRunning ? "内核运行中 · 端口 \(model.kernel.port)" : model.status.label)
            }

            if model.status.isRunning {
                Divider().frame(height: 11)
                Label(TrafficMonitor.rate(model.traffic.down), systemImage: "arrow.down")
                    .foregroundStyle(.blue)
                Label(TrafficMonitor.rate(model.traffic.up), systemImage: "arrow.up")
                    .foregroundStyle(.purple)
            }

            if model.needsRestart {
                Divider().frame(height: 11)
                Button {
                    Task {
                        await model.toggleKernel()
                        await model.startKernel()
                    }
                } label: {
                    Label("设置已改，点此重启内核", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }

            Spacer()

            if let banner = model.banner {
                HStack(spacing: 5) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isError ? .orange : .green)
                    Text(banner.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        model.banner = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            if model.helperRunning {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .help("特权助手运行中：TUN 与系统代理无需授权")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var kernelLevel: StatusDot.Level {
        switch model.status {
        case .running:             return .ok
        case .starting, .stopping: return .warn
        case .stopped:             return .off
        case .failed:              return .error
        }
    }

    // MARK: - 错误弹窗

    private var alertBinding: Binding<AppModel.Banner?> {
        Binding(
            get: { model.banner?.isError == true ? model.banner : nil },
            set: { model.banner = $0 }
        )
    }
}

/// Alert 需要一个 Identifiable 数据源
extension AppModel.Banner: CustomStringConvertible {
    var title: String { isError ? "出错了" : "提示" }
    var message: String { text }
    public var description: String { text }
}
