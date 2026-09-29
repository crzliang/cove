import SwiftUI
import AppKit

/// 主窗口：窄导航轨 + 内容区。
///
/// 对齐 ServerBox 未展开的 NavigationRail：图标在上，文字在下，设置钉在底部。
struct MainWindow: View {

    @ObservedObject var model: AppModel

    /// Flutter NavigationRail 的默认最小宽度。两字标题放在图标下面刚好放下。
    private let railWidth: CGFloat = 72

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                navRail
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

    private var railDestinations: [AppModel.SidebarItem] {
        AppModel.SidebarItem.allCases.filter { $0 != .settings }
    }

    // MARK: - 导航轨

    private var navRail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(railDestinations) { item in
                        railTile(item)
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)

            if model.status.isRunning {
                railTraffic
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
            }

            railTile(.settings)
                .padding(.bottom, 10)
        }
        .frame(width: railWidth)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) { Divider() }
    }

    private func railTile(_ item: AppModel.SidebarItem) -> some View {
        let selected = model.sidebarSelection == item
        return Button {
            model.sidebarSelection = item
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .frame(width: 56, height: 32)
                    .background {
                        if selected {
                            Capsule().fill(Color.accentColor.opacity(0.16))
                        }
                    }
                Text(item.title)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    private var railTraffic: some View {
        VStack(spacing: 1) {
            Text("↓ \(TrafficMonitor.rate(model.traffic.down))")
            Text("↑ \(TrafficMonitor.rate(model.traffic.up))")
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
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
