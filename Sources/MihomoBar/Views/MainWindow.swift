import SwiftUI
import AppKit

/// 主窗口：工具栏 + 可折叠侧边栏 + 内容区。
///
/// 侧栏折叠/展开只走按钮（工具栏 + 侧栏顶栏），不用 NavigationSplitView
/// 的拖拽隐藏——后者折叠后很难再找回。
struct MainWindow: View {

    @ObservedObject var model: AppModel

    private let sidebarWidth: CGFloat = 210

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if model.sidebarExpanded {
                    sidebar
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    collapsedSidebarRail
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: model.sidebarExpanded)
            .toolbar { windowToolbar }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.needsRestart || (model.banner.map { !$0.isError } == true) {
                transientBottomBar
            }
        }
        .alert(item: alertBinding) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message),
                  dismissButton: .default(Text("好")))
        }
    }

    private var selection: Binding<AppModel.SidebarItem?> {
        Binding(
            get: { model.sidebarSelection },
            set: { if let value = $0 { model.sidebarSelection = value } }
        )
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            List(selection: selection) {
                ForEach(AppModel.SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarTrafficStats
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }


    /// 折叠后留下窄条，保证随时能点开。
    private var collapsedSidebarRail: some View {
        VStack(spacing: 8) {
            Button {
                model.sidebarExpanded = true
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("展开侧边栏")
            .padding(.top, 8)

            ForEach(AppModel.SidebarItem.allCases) { item in
                Button {
                    model.sidebarSelection = item
                    model.sidebarExpanded = true
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 36, height: 28)
                        .foregroundStyle(model.sidebarSelection == item ? Color.accentColor : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(item.title)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 48)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// 侧栏顶栏：折叠按钮始终可见。
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Button {
                model.sidebarExpanded = false
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("折叠侧边栏")

            Text("导航")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sidebarTrafficStats: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if model.status.isRunning {
                HStack(spacing: 0) {
                    sidebarStat(title: "下行",
                                value: TrafficMonitor.rate(model.traffic.down),
                                tint: .blue)
                    sidebarStat(title: "上行",
                                value: TrafficMonitor.rate(model.traffic.up),
                                tint: .purple)
                }
                if model.connectionTotals.down > 0 || model.connectionTotals.up > 0 {
                    HStack(spacing: 0) {
                        sidebarStat(title: "累计↓",
                                    value: TrafficMonitor.volume(model.connectionTotals.down),
                                    tint: .secondary)
                        sidebarStat(title: "累计↑",
                                    value: TrafficMonitor.volume(model.connectionTotals.up),
                                    tint: .secondary)
                    }
                }
            } else {
                Text("内核未运行")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func sidebarStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - 内容

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .overview:     OverviewPane(model: model)
        case .proxies:      ProxiesPane(model: model)
        case .connections:  ConnectionsPane(model: model)
        case .rules:        RulesPane(model: model)
        case .subscription: SubscriptionPane(model: model)
        case .logs:         LogsPane(model: model)
        case .settings:     SettingsPane(model: model)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.sidebarExpanded.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(model.sidebarExpanded ? "折叠侧边栏" : "展开侧边栏")
        }

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

        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                StatusDot(level: kernelLevel)
                Text(model.status.isRunning
                     ? "端口 \(model.kernel.port)"
                     : model.status.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
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
                Task { await model.reloadConfig() }
            } label: {
                Label("重载配置", systemImage: "arrow.clockwise")
            }
            .disabled(!model.status.isRunning || model.busy)
            .help("让内核重新读取磁盘上的配置")
        }
    }

    // MARK: - 临时底栏

    private var transientBottomBar: some View {
        HStack(spacing: 14) {
            if model.needsRestart {
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

            if let banner = model.banner, !banner.isError {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
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

            Spacer(minLength: 0)
        }
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

    private var alertBinding: Binding<AppModel.Banner?> {
        Binding(
            get: { model.banner?.isError == true ? model.banner : nil },
            set: { model.banner = $0 }
        )
    }
}

extension AppModel.Banner: CustomStringConvertible {
    var title: String { isError ? "出错了" : "提示" }
    var message: String { text }
    public var description: String { text }
}
