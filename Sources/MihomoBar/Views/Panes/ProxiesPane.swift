import SwiftUI

/// 节点：左侧策略组，右侧该组的完整节点列表。
/// 菜单栏小面板放不下这些，只有正式窗口才有意义。
struct ProxiesPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.status.isRunning && !model.groups.isEmpty {
                HStack(spacing: 0) {
                    groupColumn
                    Divider()
                    nodeColumn
                }
            } else {
                Spacer()
                EmptyHint(
                    systemImage: model.status.isRunning
                        ? "list.bullet.rectangle" : "power",
                    message: model.status.isRunning
                        ? (model.settings.subscriptionURL.isEmpty
                           ? "还没有配置订阅。\n到「订阅」页填入 Clash 订阅链接后，节点会自动出现。"
                           : "订阅已配置，正在读取节点…")
                        : "内核未运行。启动内核后才能查看和切换节点。",
                    action: model.status.isRunning
                        ? nil
                        : ("启动内核", { Task { await model.toggleKernel() } }))
                Spacer()
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("节点").font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let group = model.currentGroup {
                Button {
                    Task { await model.testDelays(group: group.id) }
                } label: {
                    if model.testingDelays {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("测速中…")
                        }
                    } else {
                        Label("测速全部", systemImage: "bolt.horizontal")
                    }
                }
                .disabled(model.testingDelays || !model.status.isRunning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        guard let group = model.currentGroup else { return "尚未加载策略组" }
        let shown = filteredNodes(of: group).count
        return shown == group.options.count
            ? "\(group.name) · \(group.options.count) 个节点"
            : "\(group.name) · 匹配 \(shown) / \(group.options.count) 个节点"
    }

    // MARK: - 策略组列

    private var groupColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.groups) { group in
                    let selected = (model.currentGroup?.id == group.id)
                    Button {
                        model.selectedGroupID = group.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .lineLimit(1)
                            Text(group.now)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selected ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 190)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - 节点列

    private var nodeColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("筛选节点", text: $model.nodeSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.nodeSearch.isEmpty {
                    Button {
                        model.nodeSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let group = model.currentGroup {
                let nodes = filteredNodes(of: group)
                if nodes.isEmpty {
                    Spacer()
                    EmptyHint(systemImage: "magnifyingglass",
                              message: model.nodeSearch.isEmpty
                                  ? "这个策略组没有可切换的节点"
                                  : "没有匹配「\(model.nodeSearch)」的节点")
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(nodes, id: \.self) { node in
                                nodeRow(node, in: group)
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func filteredNodes(of group: AppModel.GroupInfo) -> [String] {
        let keyword = model.nodeSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return group.options }
        return group.options.filter { $0.lowercased().contains(keyword) }
    }

    private func nodeRow(_ node: String, in group: AppModel.GroupInfo) -> some View {
        let isCurrent = (node == group.now)
        let delay = model.nodeDelays[node] ?? nil
        return Button {
            Task { await model.select(group: group.id, node: node) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isCurrent ? Color.accentColor
                                               : Color(nsColor: .tertiaryLabelColor))
                Text(node)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let delay {
                    Text(DelayStyle.text(delay))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(DelayStyle.color(delay))
                }
                Button {
                    Task { await model.testSingleDelay(node) }
                } label: {
                    Image(systemName: "bolt")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("测试该节点延迟")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isCurrent ? Color.accentColor.opacity(0.09) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
