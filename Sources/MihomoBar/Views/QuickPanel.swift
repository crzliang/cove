import SwiftUI

/// 菜单栏弹出面板。
///
/// 定位是「扫一眼 + 快速操作」：状态、启停、系统代理、模式、当前线路。
/// 完整功能（节点全列表、订阅、日志、设置）都在主窗口里，
/// 点右上角或底部的按钮跳过去。
struct QuickPanel: View {

    @ObservedObject var model: AppModel
    var onOpenWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    primaryControls
                    if model.status.isRunning {
                        trafficRow
                        if !model.groups.isEmpty { currentNodes }
                    }
                    Divider()
                    footerActions
                }
                .padding(13)
            }
        }
        .frame(width: 340, height: 460)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(level: kernelLevel)
            VStack(alignment: .leading, spacing: 1) {
                Text("MihomoBar").font(.system(size: 13, weight: .semibold))
                Text(model.status.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button {
                onOpenWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("打开主窗口")
        }
        .padding(.horizontal, 13)
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

    // MARK: - 主控

    private var primaryControls: some View {
        VStack(spacing: 9) {
            Button {
                Task { await model.toggleKernel() }
            } label: {
                Label(model.status.isRunning ? "停止内核" : "启动内核",
                      systemImage: model.status.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.status.isBusy || model.busy)

            Toggle(isOn: Binding(
                get: { model.systemProxyOn },
                set: { on in Task { await model.setSystemProxy(on) } })) {
                Text("系统代理")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.status.isRunning || model.busy)

            Picker("", selection: Binding(
                get: { model.mode },
                set: { m in Task { await model.setMode(m) } })) {
                Text("规则").tag("rule")
                Text("全局").tag("global")
                Text("直连").tag("direct")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.status.isRunning)
        }
    }

    // MARK: - 流量

    private var trafficRow: some View {
        HStack(spacing: 10) {
            Label(TrafficMonitor.rate(model.traffic.down), systemImage: "arrow.down")
                .foregroundStyle(.blue)
            Label(TrafficMonitor.rate(model.traffic.up), systemImage: "arrow.up")
                .foregroundStyle(.purple)
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
    }

    // MARK: - 当前线路

    private var currentNodes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("当前线路")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(model.groups.prefix(4)) { group in
                HStack(spacing: 8) {
                    Text(group.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .leading)
                        .lineLimit(1)
                    Text(group.now)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let delay = model.nodeDelays[group.now] ?? group.delay {
                        Text("\(delay)")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(DelayStyle.color(delay))
                    }
                }
            }

            Button {
                model.selectedGroupID = model.groups.first?.id
                model.sidebarSelection = .proxies
                onOpenWindow()
            } label: {
                Label("切换节点", systemImage: "arrow.left.arrow.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - 底部操作

    private var footerActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.openDashboard()
                } label: {
                    Label("面板", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .disabled(!model.status.isRunning)

                Button {
                    Task { await model.reloadConfig() }
                } label: {
                    Label("重载", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .disabled(!model.status.isRunning || model.busy)
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Button {
                    onOpenWindow()
                } label: {
                    Label("主窗口", systemImage: "macwindow").frame(maxWidth: .infinity)
                }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("退出").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)
        }
    }
}
