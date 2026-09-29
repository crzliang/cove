import SwiftUI

/// 节点：策略组卡片网格（仿 zashboard）。
struct ProxiesPane: View {
    @ObservedObject var model: AppModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 10, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.status.isRunning && !model.groups.isEmpty {
                searchBar
                Divider()
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(model.groups) { group in
                            groupCard(group)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(16)
                }
            } else {
                Spacer()
                EmptyHint(
                    systemImage: model.status.isRunning
                        ? "list.bullet.rectangle" : "power",
                    message: model.status.isRunning
                        ? (model.settings.activeSubscriptions.isEmpty
                           ? "还没有配置订阅。\n到「订阅」页添加 Clash 订阅链接后，节点会自动出现。"
                           : "订阅已配置，正在读取节点…")
                        : "内核未运行。启动内核后才能查看和切换节点。",
                    action: model.status.isRunning
                        ? nil
                        : ("启动内核", { Task { await model.toggleKernel() } }))
                Spacer()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("节点").font(.system(size: 22, weight: .semibold))
                Text(model.groups.isEmpty
                     ? "尚未加载策略组"
                     : "\(model.groups.count) 个策略组")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
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
                        Label("测速当前组", systemImage: "bolt.horizontal")
                    }
                }
                .controlSize(.small)
                .disabled(model.testingDelays || !model.status.isRunning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("筛选节点（展开组内生效）", text: $model.nodeSearch)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func groupCard(_ group: AppModel.GroupInfo) -> some View {
        let expanded = model.expandedProxyGroups.contains(group.id)
        let delay = model.nodeDelays[group.now] ?? group.delay
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                model.selectedGroupID = group.id
                model.toggleProxyGroupExpanded(group.id)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(DisplayName.proxy(group.name))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(DisplayName.proxy(group.now))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Text(DelayStyle.text(delay))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(DelayStyle.color(delay))
                    Text("\(group.options.count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: .separatorColor).opacity(0.35), in: Capsule())
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().padding(.horizontal, 12)
                let nodes = filteredNodes(of: group)
                if nodes.isEmpty {
                    Text("没有匹配的节点")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(nodes, id: \.self) { node in
                            nodeRow(node, in: group)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
    }

    private func filteredNodes(of group: AppModel.GroupInfo) -> [String] {
        let keyword = model.nodeSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let base = keyword.isEmpty
            ? group.options
            : group.options.filter { $0.lowercased().contains(keyword) }

        return base.sorted { a, b in
            let aCurrent = a == group.now
            let bCurrent = b == group.now
            if aCurrent != bCurrent { return aCurrent }
            let da = model.nodeDelays[a]
            let db = model.nodeDelays[b]
            switch (da, db) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }

    private func nodeRow(_ node: String, in group: AppModel.GroupInfo) -> some View {
        let isCurrent = (node == group.now)
        let delay = model.nodeDelays[node]
        return Button {
            Task { await model.select(group: group.id, node: node) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? Color.accentColor
                                               : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 14)

                Text(DisplayName.proxy(node))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(DelayStyle.text(delay))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(DelayStyle.color(delay))
                    .frame(width: 56, alignment: .trailing)

                Button {
                    Task { await model.testSingleDelay(node) }
                } label: {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("测试该节点延迟")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isCurrent ? Color.accentColor.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
