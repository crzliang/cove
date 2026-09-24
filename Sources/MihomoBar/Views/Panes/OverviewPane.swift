import SwiftUI

/// 概览：一眼看清当前状态 + 最常用的操作。
struct OverviewPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PaneScaffold(title: "概览", subtitle: model.versionSummary) {
            statusGrid
            trafficCard
            if model.status.isRunning {
                currentNodesCard
            } else {
                Card(title: "开始使用", systemImage: "play.circle") {
                    EmptyHint(
                        systemImage: "shield.lefthalf.filled",
                        message: "内核尚未运行。启动后即可在「节点」页切换线路，\n或在浏览器面板里查看规则与连接明细。",
                        action: ("启动内核", { Task { await model.toggleKernel() } }))
                }
            }
            quickActionsCard
        }
    }

    // MARK: - 状态

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            statusTile(
                title: "内核",
                value: model.status.isRunning ? "运行中" : (model.status.isBusy ? "切换中" : "已停止"),
                detail: model.status.isRunning ? "端口 \(model.kernel.port)" : nil,
                level: kernelLevel,
                symbol: "cpu",
                action: { Task { await model.toggleKernel() } })

            statusTile(
                title: "系统代理",
                value: model.systemProxyOn ? "已开启" : "已关闭",
                detail: "127.0.0.1:\(String(model.settings.mixedPort))",
                level: model.systemProxyOn ? .ok : .off,
                symbol: "network",
                action: { Task { await model.setSystemProxy(!model.systemProxyOn) } })

            statusTile(
                title: "TUN 模式",
                value: model.settings.tunEnabled ? "已开启" : "已关闭",
                detail: model.settings.tunEnabled ? "全局接管" : "仅本地端口",
                level: model.settings.tunEnabled ? .ok : .off,
                symbol: "arrow.triangle.branch")

            statusTile(
                title: "特权助手",
                value: model.helperRunning ? "运行中" : (model.helperInstalled ? "未运行" : "未安装"),
                detail: model.helperRunning ? "免授权" : "需安装",
                level: model.helperRunning ? .ok : (model.helperInstalled ? .warn : .off),
                symbol: "checkmark.shield",
                action: {
                    if model.helperInstalled {
                        model.sidebarSelection = .settings
                    } else {
                        Task { await model.installHelper() }
                    }
                })
        }
    }

    private var kernelLevel: StatusDot.Level {
        switch model.status {
        case .running:             return .ok
        case .starting, .stopping: return .warn
        case .stopped:             return .off
        case .failed:              return .error
        }
    }

    private func statusTile(title: String, value: String, detail: String?,
                            level: StatusDot.Level, symbol: String,
                            action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    StatusDot(level: level)
                }
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: - 流量

    private var trafficCard: some View {
        Card(title: "实时流量", systemImage: "chart.line.uptrend.xyaxis") {
            if model.status.isRunning {
                HStack(spacing: 10) {
                    StatTile(title: "下行", value: TrafficMonitor.rate(model.traffic.down),
                             systemImage: "arrow.down", tint: .blue)
                    StatTile(title: "上行", value: TrafficMonitor.rate(model.traffic.up),
                             systemImage: "arrow.up", tint: .purple)
                }
            } else {
                Text("内核未运行")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - 当前节点

    private var currentNodesCard: some View {
        Card(title: "当前线路", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 0) {
                if model.groups.isEmpty {
                    Text(model.settings.subscriptionURL.isEmpty
                         ? "还没有配置订阅，可在「订阅」页添加"
                         : "正在读取策略组…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                }
                ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().padding(.vertical, 8) }
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(group.now)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if let delay = model.nodeDelays[group.now] ?? group.delay {
                            Text(DelayStyle.text(delay))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(DelayStyle.color(delay))
                        }
                        Button("切换") {
                            model.selectedGroupID = group.id
                            model.sidebarSelection = .proxies
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - 快捷操作

    private var quickActionsCard: some View {
        Card(title: "快捷操作", systemImage: "command") {
            HStack(spacing: 8) {
                Button {
                    model.openDashboard()
                } label: {
                    Label("浏览器面板", systemImage: "safari")
                }
                .disabled(!model.status.isRunning)

                Button {
                    Task { await model.reloadConfig() }
                } label: {
                    Label("重载配置", systemImage: "arrow.clockwise")
                }
                .disabled(!model.status.isRunning || model.busy)

                Button {
                    model.revealDataDir()
                } label: {
                    Label("数据目录", systemImage: "folder")
                }

                Spacer()
            }
            .controlSize(.regular)
        }
    }
}
