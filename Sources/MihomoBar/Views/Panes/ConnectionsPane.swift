import SwiftUI
import AppKit

/// 连接：表头可排序；点击行在右侧查看详细信息。
struct ConnectionsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.status.isRunning {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    listColumn
                    if model.selectedConnectionID != nil {
                        Divider()
                        detailPanel
                            .frame(width: 300)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                EmptyHint(systemImage: "power",
                          message: "内核未运行。\n启动内核后，这里会实时列出所有经过代理的连接。",
                          action: ("启动内核", { Task { await model.toggleKernel() } }))
                Spacer()
            }
        }
        .task(id: model.status.isRunning) {
            guard model.status.isRunning else { return }
            await model.refreshConnections()
        }
    }

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

            Spacer()
            Text("点击行查看详情")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - 列表

    private var listColumn: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                columnHeader
                Divider()
                connectionList
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columnHeader: some View {
        HStack(spacing: ConnCols.spacing) {
            sortHeader("主机", .host)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("规则", .rule)
                .frame(width: ConnCols.rule, alignment: .leading)
            sortHeader("链路", .chains)
                .frame(width: ConnCols.chains, alignment: .leading)
            sortHeader("流量", .traffic)
                .frame(width: ConnCols.traffic, alignment: .trailing)
            sortHeader("时长", .duration)
                .frame(width: ConnCols.duration, alignment: .trailing)
            Color.clear.frame(width: ConnCols.close)
        }
        .padding(.horizontal, ConnCols.hPad)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sortHeader(_ title: String, _ column: AppModel.ConnectionSortColumn) -> some View {
        let active = model.connectionSortColumn == column
        let align: Alignment = (column == .traffic || column == .duration) ? .trailing : .leading
        return Button {
            model.toggleConnectionSort(column)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                if active {
                    Image(systemName: model.connectionSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, alignment: align)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var connectionList: some View {
        let items = model.visibleConnections
        if items.isEmpty {
            VStack {
                EmptyHint(
                    systemImage: model.connections.isEmpty
                        ? "moon.zzz" : "magnifyingglass",
                    message: model.connections.isEmpty
                        ? "当前没有活动连接。\n有流量经过代理时会自动出现。"
                        : "没有匹配「\(model.connectionSearch)」的连接")
                Spacer(minLength: 0)
            }
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { conn in
                        ConnectionRow(
                            conn: conn,
                            rate: model.rate(for: conn),
                            selected: model.selectedConnectionID == conn.id,
                            onSelect: {
                                if model.selectedConnectionID == conn.id {
                                    model.selectedConnectionID = nil
                                } else {
                                    model.selectedConnectionID = conn.id
                                }
                            },
                            onClose: {
                                Task { await model.closeConnection(conn.id) }
                            })
                        Divider().padding(.leading, ConnCols.hPad)
                    }
                }
            }
        }
    }

    // MARK: - 详情

    private var detailPanel: some View {
        let conn = model.connections.first { $0.id == model.selectedConnectionID }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("连接详情")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    model.selectedConnectionID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭详情")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if let conn {
                ScrollView {
                    ConnectionDetailView(conn: conn, rate: model.rate(for: conn)) {
                        Task { await model.closeConnection(conn.id) }
                    }
                    .padding(14)
                }
            } else {
                Text("连接已结束")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(maxHeight: .infinity)
    }
}

// MARK: - 列宽（表头与行共用）

private enum ConnCols {
    static let spacing: CGFloat = 10
    static let hPad: CGFloat = 20
    static let rule: CGFloat = 120
    static let chains: CGFloat = 140
    static let traffic: CGFloat = 100
    static let duration: CGFloat = 72
    static let close: CGFloat = 22
}

// MARK: - 单行

private struct ConnectionRow: View {
    let conn: CtlClient.Connection
    let rate: AppModel.Rate?
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var meta: CtlClient.Connection.Metadata? { conn.metadata }

    private var title: String {
        if let host = meta?.host, !host.isEmpty { return host }
        if let sniff = meta?.sniffHost, !sniff.isEmpty { return sniff }
        if let ip = meta?.destinationIP, !ip.isEmpty { return ip }
        return conn.rulePayload?.isEmpty == false ? conn.rulePayload! : "—"
    }

    private var destinationPort: String { meta?.destinationPort?.value ?? "" }

    var body: some View {
        HStack(alignment: .center, spacing: ConnCols.spacing) {
            Button(action: onSelect) {
                HStack(alignment: .center, spacing: ConnCols.spacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title + (destinationPort.isEmpty ? "" : ":\(destinationPort)"))
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let network = meta?.network {
                                Badge(text: network.uppercased(), tint: .secondary)
                            }
                        }
                        if let proc = processName {
                            Text(proc)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(ruleText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: ConnCols.rule, alignment: .leading)

                    Text(chainsText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: ConnCols.chains, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 1) {
                        if let rate, rate.up > 1 || rate.down > 1 {
                            Text("↓\(TrafficMonitor.rate(Int(rate.down))) ↑\(TrafficMonitor.rate(Int(rate.up)))")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                        }
                        Text(TrafficMonitor.volume(conn.download + conn.upload))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: ConnCols.traffic, alignment: .trailing)

                    Text(duration)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: ConnCols.duration, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("断开这条连接")
            .frame(width: ConnCols.close)
        }
        .padding(.horizontal, ConnCols.hPad)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.10) : .clear)
    }

    private var ruleText: String {
        guard let rule = conn.rule, !rule.isEmpty else { return "—" }
        if let payload = conn.rulePayload, !payload.isEmpty {
            return "\(rule),\(payload)"
        }
        return rule
    }

    private var chainsText: String {
        guard let chains = conn.chains, !chains.isEmpty else { return "—" }
        return chains.reversed().joined(separator: " → ")
    }

    private var processName: String? {
        guard let p = meta?.process, !p.isEmpty else { return nil }
        return (p as NSString).lastPathComponent
    }

    private var duration: String {
        guard let date = conn.startDate else { return "—" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(0, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

// MARK: - 详情面板

private struct ConnectionDetailView: View {
    let conn: CtlClient.Connection
    let rate: AppModel.Rate?
    let onClose: () -> Void

    private var meta: CtlClient.Connection.Metadata? { conn.metadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("网络") {
                detailRow("协议", meta?.network?.uppercased() ?? "—")
                detailRow("类型", meta?.type ?? "—")
                detailRow("DNS 模式", meta?.dnsMode ?? "—")
            }

            section("地址") {
                detailRow("源 IP", meta?.sourceIP ?? "—")
                detailRow("源端口", meta?.sourcePort?.value ?? "—")
                detailRow("目的 IP", meta?.destinationIP ?? "—")
                detailRow("目的端口", meta?.destinationPort?.value ?? "—")
                detailRow("主机", display(meta?.host) ?? "—")
                detailRow("嗅探主机", display(meta?.sniffHost) ?? "—")
                detailRow("远端", display(meta?.remoteDestination) ?? "—")
            }

            section("路由") {
                detailRow("规则", ruleText)
                detailRow("链路", chainsText)
            }

            section("进程") {
                let procName: String = {
                    guard let p = display(meta?.process) else { return "—" }
                    return (p as NSString).lastPathComponent
                }()
                detailRow("进程", procName)
                detailRow("路径", display(meta?.processPath) ?? "—")
            }

            section("地理 / ASN") {
                detailRow("源 GeoIP", geoText(meta?.sourceGeoIP))
                detailRow("目的 GeoIP", geoText(meta?.destinationGeoIP))
                detailRow("源 ASN", display(meta?.sourceIPASN) ?? "—")
                detailRow("目的 ASN", display(meta?.destinationIPASN) ?? "—")
            }

            section("流量") {
                if let rate {
                    detailRow("下行速率", TrafficMonitor.rate(Int(rate.down)))
                    detailRow("上行速率", TrafficMonitor.rate(Int(rate.up)))
                }
                detailRow("累计下载", TrafficMonitor.volume(conn.download))
                detailRow("累计上传", TrafficMonitor.volume(conn.upload))
                detailRow("开始时间", startText)
                detailRow("已持续", durationText)
            }

            Button(role: .destructive, action: onClose) {
                Label("断开此连接", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)
            VStack(alignment: .leading, spacing: 5) {
                content()
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func display(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private func geoText(_ arr: [String]?) -> String {
        guard let arr, !arr.isEmpty else { return "—" }
        return arr.joined(separator: ", ")
    }

    private var ruleText: String {
        guard let rule = conn.rule, !rule.isEmpty else { return "—" }
        if let payload = conn.rulePayload, !payload.isEmpty {
            return "\(rule), \(payload)"
        }
        return rule
    }

    private var chainsText: String {
        guard let chains = conn.chains, !chains.isEmpty else { return "—" }
        return chains.reversed().joined(separator: " → ")
    }

    private var startText: String {
        guard let date = conn.startDate else { return conn.start }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private var durationText: String {
        guard let date = conn.startDate else { return "—" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(0, seconds)) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds / 3600) 时 \((seconds % 3600) / 60) 分"
    }
}

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
