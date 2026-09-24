import SwiftUI
import Charts

/// 概览：状态 + 流量曲线 + 当前线路（仿 zashboard 信息密度，原生风格）。
struct OverviewPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PaneScaffold(title: "概览", subtitle: model.versionSummary) {
            statusStrip
            if model.status.isRunning {
                trafficSection
                metricsStrip
                currentNodesCard
            } else {
                Card(title: "开始使用", systemImage: "play.circle") {
                    EmptyHint(
                        systemImage: "shield.lefthalf.filled",
                        message: "内核尚未运行。启动后即可在「节点」页切换线路，\n在「连接」页查看实时连接明细。",
                        action: ("启动内核", { Task { await model.toggleKernel() } }))
                }
            }
            quickActions
        }
    }

    // MARK: - 状态

    private var statusStrip: some View {
        HStack(spacing: 0) {
            statusCell(
                title: "内核",
                value: model.status.isRunning ? "运行中" : (model.status.isBusy ? "切换中" : "已停止"),
                detail: model.status.isRunning ? ":\(model.kernel.port)" : nil,
                level: kernelLevel,
                symbol: "cpu",
                action: { Task { await model.toggleKernel() } })

            stripDivider

            statusCell(
                title: "系统代理",
                value: model.systemProxyOn ? "已开启" : "已关闭",
                detail: ":\(model.settings.mixedPort)",
                level: model.systemProxyOn ? .ok : .off,
                symbol: "network",
                action: { Task { await model.setSystemProxy(!model.systemProxyOn) } })

            stripDivider

            statusCell(
                title: "TUN",
                value: tunActive ? "已开启" : "已关闭",
                detail: tunActive ? "全局接管" : (model.settings.tunEnabled ? "待重启" : "仅端口"),
                level: tunActive ? .ok : (model.settings.tunEnabled ? .warn : .off),
                symbol: "arrow.triangle.branch",
                action: {
                    Task { await model.setTunEnabled(!model.settings.tunEnabled) }
                })

            stripDivider

            statusCell(
                title: "助手",
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    /// 设置开了 TUN，且内核确实以 root 在跑。
    private var tunActive: Bool {
        model.settings.tunEnabled && model.status.isRunning && model.kernel.isPrivileged
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 0.5)
            .padding(.vertical, 10)
    }

    private var kernelLevel: StatusDot.Level {
        switch model.status {
        case .running:             return .ok
        case .starting, .stopping: return .warn
        case .stopped:             return .off
        case .failed:              return .error
        }
    }

    private func statusCell(title: String, value: String, detail: String?,
                            level: StatusDot.Level, symbol: String,
                            action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    StatusDot(level: level)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: - 流量曲线

    private var trafficSection: some View {
        Card(title: "实时流量", systemImage: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Label(TrafficMonitor.rate(model.traffic.down), systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                    Label(TrafficMonitor.rate(model.traffic.up), systemImage: "arrow.up")
                        .foregroundStyle(.purple)
                    Spacer()
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()

                trafficChart
                    .frame(height: 120)
            }
        }
    }

    @ViewBuilder
    private var trafficChart: some View {
        let points = model.traffic.history
        if points.count < 2 {
            Text("采集中…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(points) { p in
                    LineMark(
                        x: .value("时间", p.at),
                        y: .value("下行", p.down)
                    )
                    .foregroundStyle(by: .value("方向", "下行"))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", p.at),
                        y: .value("上行", p.up)
                    )
                    .foregroundStyle(by: .value("方向", "上行"))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartForegroundStyleScale([
                "下行": Color.blue,
                "上行": Color.purple,
            ])
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let n = value.as(Int.self) {
                            Text(compactRate(n))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
        }
    }

    private func compactRate(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)" }
        if bytes < 1024 * 1024 { return String(format: "%.0fK", Double(bytes) / 1024) }
        return String(format: "%.1fM", Double(bytes) / 1024 / 1024)
    }

    // MARK: - 小指标

    private var metricsStrip: some View {
        HStack(spacing: 8) {
            metricChip(title: "连接", value: "\(model.connections.count)",
                       systemImage: "arrow.left.arrow.right")
            metricChip(title: "累计↓", value: TrafficMonitor.volume(model.connectionTotals.down),
                       systemImage: "arrow.down")
            metricChip(title: "累计↑", value: TrafficMonitor.volume(model.connectionTotals.up),
                       systemImage: "arrow.up")
            metricChip(title: "内存占用",
                       value: model.connectionMemory > 0
                         ? TrafficMonitor.volume(model.connectionMemory) : "—",
                       systemImage: "memorychip")
            Button {
                Task { await model.refreshExitIP(force: true) }
            } label: {
                metricChip(title: "出口 IP",
                           value: exitIPText,
                           systemImage: "globe")
            }
            .buttonStyle(.plain)
            .help("点击重新探测出口 IP")
            Spacer(minLength: 0)
        }
    }

    private var exitIPText: String {
        if model.exitIPRefreshing && model.exitIP == nil { return "探测中…" }
        if let ip = model.exitIP, !ip.isEmpty { return ip }
        return model.exitIPRefreshing ? "探测中…" : "—"
    }

    private func metricChip(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: - 当前线路

    private var currentNodesCard: some View {
        Card(title: "当前线路", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 0) {
                if model.groups.isEmpty {
                    Text(model.settings.activeSubscriptions.isEmpty
                         ? "还没有配置订阅，可在「订阅」页添加"
                         : "正在读取策略组…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
                ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().padding(.vertical, 6) }
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
                        Button {
                            model.selectedGroupID = group.id
                            model.sidebarSelection = .proxies
                        } label: {
                            Text("切换")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - 快捷操作

    private var quickActions: some View {
        HStack(spacing: 8) {
            actionButton("重载配置", "arrow.clockwise",
                         enabled: model.status.isRunning && !model.busy) {
                Task { await model.reloadConfig() }
            }
            actionButton("数据目录", "folder", enabled: true) {
                model.revealDataDir()
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ title: String, _ symbol: String,
                              enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
