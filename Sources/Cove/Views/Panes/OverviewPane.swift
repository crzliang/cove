import SwiftUI
import Charts

/// 概览：流量主卡片，下面控制和状态并排两张卡，再下面是当前线路。
///
/// 「控制 / 状态」用和「当前线路」一样的行：左边名称，右边开关或读数。
struct OverviewPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PaneScaffold(title: "概览", subtitle: model.versionSummary) {
            if showsDashboard {
                liveCard
                controlAndStatus
                currentNodesCard
            } else {
                Card(title: "开始使用", systemImage: "play.circle") {
                    EmptyHint(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        message: "内核尚未运行。启动后即可在「节点」页切换线路，\n在「连接」页查看实时连接明细。",
                        action: ("启动内核", { Task { await model.toggleKernel() } }))
                }
            }
        }
    }

    /// TUN / 启停过程中保持概览骨架，只刷新内核状态，不要整页切走。
    private var showsDashboard: Bool {
        if model.busy { return true }
        switch model.status {
        case .stopped: return false
        default: return true
        }
    }

    private var kernelStatusText: String {
        switch model.status {
        case .running(let port):
            return "运行中 :\(port)"
        case .failed:
            return "启动失败"
        case .stopped where !model.busy:
            return "停止运行"
        case .starting, .stopping, .stopped:
            return "正在重启…"
        }
    }

    private var kernelStatusLevel: StatusDot.Level {
        switch model.status {
        case .running: return .ok
        case .failed: return .error
        case .stopped where !model.busy: return .off
        default: return .warn
        }
    }

    // MARK: - 流量

    private var liveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下行")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(TrafficMonitor.rate(model.traffic.down))
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("上行")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(TrafficMonitor.rate(model.traffic.up))
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                trafficChart
                    .frame(height: 148)
            }
        }
    }

    // MARK: - 控制 | 状态

    private var controlAndStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            Card(title: "控制", systemImage: "slider.horizontal.3") {
                VStack(spacing: 0) {
                    switchRow("系统代理", symbol: "network", isOn: model.systemProxyOn) { on in
                        Task { await model.setSystemProxy(on) }
                    }
                    switchRow("TUN", symbol: "arrow.triangle.branch", isOn: model.settings.tunEnabled) { on in
                        Task { await model.setTunEnabled(on) }
                    }
                    readingRow("重载配置", symbol: "arrow.clockwise", value: "立即", showsChevron: true) {
                        Task { await model.reloadConfig() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Card(title: "状态", systemImage: "info.circle") {
                VStack(spacing: 0) {
                    readingRow("内核", symbol: "cpu",
                               value: kernelStatusText,
                               level: kernelStatusLevel)
                    readingRow("连接", symbol: "arrow.left.arrow.right",
                               value: "\(model.connections.count)",
                               showsChevron: true) {
                        model.sidebarSelection = .connections
                    }
                    readingRow("内存", symbol: "memorychip",
                               value: model.connectionMemory > 0
                                 ? TrafficMonitor.volume(model.connectionMemory) : "—")
                    readingRow("出口 IP", symbol: "globe", value: exitIPText, showsChevron: true) {
                        Task { await model.refreshExitIP(force: true) }
                    }
                    readingRow("累计", symbol: "arrow.up.arrow.down",
                               value: "↓ \(TrafficMonitor.volume(model.connectionTotals.down))  ↑ \(TrafficMonitor.volume(model.connectionTotals.up))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func readingRow(_ title: String,
                            symbol: String,
                            value: String,
                            level: StatusDot.Level? = nil,
                            showsChevron: Bool = false,
                            action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                if let level {
                    StatusDot(level: level)
                }
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func switchRow(_ title: String,
                           symbol: String,
                           isOn: Bool,
                           action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { action($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
            .disabled(model.busy || model.status.isBusy)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 流量曲线

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
                    AreaMark(
                        x: .value("时间", p.at),
                        y: .value("下行", p.down)
                    )
                    .foregroundStyle(by: .value("方向", "下行"))
                    .interpolationMethod(.catmullRom)
                    .opacity(0.18)

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
                "下行": Color.accentColor,
                "上行": Color.accentColor.opacity(0.35),
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

    private var exitIPText: String {
        if model.exitIPRefreshing && model.exitIP == nil { return "探测中…" }
        if let ip = model.exitIP, !ip.isEmpty { return ip }
        return model.exitIPRefreshing ? "探测中…" : "—"
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
                ForEach(model.groups) { group in
                    Button {
                        model.selectedGroupID = group.id
                        model.sidebarSelection = .proxies
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: groupIcon(group.name))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                            Text(DisplayName.proxy(group.name))
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DisplayName.proxy(group.now))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let delay = model.nodeDelays[group.now] ?? group.delay {
                                Text(DelayStyle.text(delay))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(DelayStyle.color(delay))
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func groupIcon(_ name: String) -> String {
        if name.contains("自动") || name.localizedCaseInsensitiveContains("auto") {
            return "arrow.triangle.2.circlepath"
        }
        if name.contains("节点") || name.contains("选择") {
            return "paperplane.fill"
        }
        return "point.3.connected.trianglepath.dotted"
    }

}
