import SwiftUI
import AppKit

/// 连接：当前所有活动连接。
///
/// 每行给全用户关心的信息：源 IP:端口 → 目的 IP:端口、协议、命中规则、
/// 代理链路、实时速率、已持续时长。
///
/// 「网速」是本地按两次轮询的字节差算出来的 —— mihomo 的 /connections
/// 只给单条连接的**累计**字节数，没有速率字段。
struct ConnectionsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.status.isRunning {
                toolbar
                Divider()
                list
            } else {
                Spacer()
                EmptyHint(systemImage: "power",
                          message: "内核未运行。\n启动内核后，这里会实时列出所有经过代理的连接。",
                          action: ("启动内核", { Task { await model.toggleKernel() } }))
                Spacer()
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("连接").font(.system(size: 20, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    Task { await model.refreshConnections() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    Task { await model.closeAllConnections() }
                } label: {
                    Label("全部断开", systemImage: "xmark.circle")
                }
                .disabled(model.connections.isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var summary: String {
        guard model.status.isRunning else { return "内核未运行" }
        var parts: [String] = ["\(model.connections.count) 个活动连接"]
        parts.append("累计 ↑ \(TrafficMonitor.volume(model.connectionTotals.up))")
        parts.append("↓ \(TrafficMonitor.volume(model.connectionTotals.down))")
        if model.connectionMemory > 0 {
            parts.append("内存 \(TrafficMonitor.volume(model.connectionMemory))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 筛选栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("筛选主机 / IP / 进程 / 规则", text: $model.connectionSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.connectionSearch.isEmpty {
                    Button {
                        model.connectionSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))

            Toggle(isOn: $model.connectionSortByTraffic) {
                Text("按流量排序").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - 列表

    private var list: some View {
        let items = model.visibleConnections
        return Group {
            if items.isEmpty {
                VStack {
                    EmptyHint(
                        systemImage: model.connections.isEmpty
                            ? "moon.zzz" : "magnifyingglass",
                        message: model.connections.isEmpty
                            ? "当前没有活动连接。\n有流量经过代理时会自动出现。"
                            : "没有匹配「\(model.connectionSearch)」的连接")
                    Spacer()
                }
                .padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { conn in
                            ConnectionRow(conn: conn, rate: model.rate(for: conn)) {
                                Task { await model.closeConnection(conn.id) }
                            }
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 单行

private struct ConnectionRow: View {
    let conn: CtlClient.Connection
    let rate: AppModel.Rate?
    let onClose: () -> Void

    private var meta: CtlClient.Connection.Metadata? { conn.metadata }

    /// 优先显示域名，没有就退回目标 IP
    private var title: String {
        if let host = meta?.host, !host.isEmpty { return host }
        if let sniff = meta?.sniffHost, !sniff.isEmpty { return sniff }
        if let ip = meta?.destinationIP, !ip.isEmpty { return ip }
        return conn.rulePayload?.isEmpty == false ? conn.rulePayload! : "—"
    }

    private var destinationPort: String { meta?.destinationPort?.value ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 第一行：主机:端口 + 协议徽章
                HStack(spacing: 6) {
                    Text(title + (destinationPort.isEmpty ? "" : ":\(destinationPort)"))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let network = meta?.network { Badge(text: network.uppercased(), tint: .secondary) }
                    if let type = meta?.type, !type.isEmpty { Badge(text: type, tint: .blue) }
                }

                // 第二行：源 → 目的
                HStack(spacing: 5) {
                    Text(endpoint(meta?.sourceIP, meta?.sourcePort?.value))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(endpoint(meta?.destinationIP, destinationPort))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)

                // 第三行：规则 + 链路 + 进程
                HStack(spacing: 10) {
                    if let rule = conn.rule, !rule.isEmpty {
                        Label(ruleText(rule), systemImage: "line.3.horizontal.decrease")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    if let chains = conn.chains, !chains.isEmpty {
                        Label(chains.reversed().joined(separator: " → "),
                              systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    if let proc = processName {
                        Label(proc, systemImage: "app")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 右侧：速率 + 累计 + 时长
            VStack(alignment: .trailing, spacing: 3) {
                if let rate, rate.up > 1 || rate.down > 1 {
                    HStack(spacing: 8) {
                        Text("↑ \(TrafficMonitor.rate(Int(rate.up)))").foregroundStyle(.purple)
                        Text("↓ \(TrafficMonitor.rate(Int(rate.down)))").foregroundStyle(.blue)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                }
                Text("累计 ↑ \(TrafficMonitor.volume(conn.upload))  ↓ \(TrafficMonitor.volume(conn.download))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(duration)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("断开这条连接")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    private func endpoint(_ ip: String?, _ port: String?) -> String {
        let host = (ip?.isEmpty == false) ? ip! : "—"
        guard let port, !port.isEmpty else { return host }
        return "\(host):\(port)"
    }

    private func ruleText(_ rule: String) -> String {
        guard let payload = conn.rulePayload, !payload.isEmpty else { return rule }
        return "\(rule),\(payload)"
    }

    private var processName: String? {
        guard let p = meta?.process, !p.isEmpty else { return nil }
        return (p as NSString).lastPathComponent
    }

    private var duration: String {
        guard let date = CtlClient.Connection.parseStart(conn.start) else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(0, seconds)) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds / 3600) 时 \((seconds % 3600) / 60) 分"
    }

}

// MARK: - 小徽章

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(tint)
    }
}
