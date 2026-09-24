import SwiftUI

/// 订阅：多链接管理 + 分别/全部更新。
struct SubscriptionPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PaneScaffold(title: "订阅", subtitle: "可添加多条 Clash / Mihomo 订阅（需返回 YAML）") {
            Card(title: "订阅列表", systemImage: "list.bullet",
                 accessory: {
                if !model.settings.subscriptions.isEmpty {
                    Button {
                        Task { await model.refreshSubscription() }
                    } label: {
                        Label("全部更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .disabled(model.busy || model.settings.activeSubscriptions.isEmpty)
                }
            }) {
                if model.settings.subscriptions.isEmpty {
                    Text("还没有订阅。在下方添加一条链接即可。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.settings.subscriptions.enumerated()), id: \.element.id) { index, sub in
                            if index > 0 { Divider().padding(.vertical, 10) }
                            subscriptionRow(sub)
                        }
                    }
                }
            }

            Card(title: "添加订阅", systemImage: "plus.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("名称（可选，如「机场 A」）", text: $model.draftSubName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    TextField("https://example.com/subscribe?token=…&client=clash", text: $model.draftSubURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    HStack {
                        Button {
                            Task {
                                await model.addSubscription(name: model.draftSubName, url: model.draftSubURL)
                            }
                        } label: {
                            if model.busy && model.updatingSubscriptionID == nil {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.small)
                                    Text("添加中…")
                                }
                            } else {
                                Label("添加并更新", systemImage: "plus")
                            }
                        }
                        .disabled(model.busy || model.draftSubURL.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("保存后立刻用系统网络下载")

                        Spacer()
                    }
                    .controlSize(.regular)

                    Text("通用分享链接需带 client=clash 等参数，返回 Clash YAML。多条订阅的节点会合到「节点选择」里。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card(title: "拉取状态", systemImage: "info.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    InfoRow("汇总", value: model.providerInfo
                            ?? (model.settings.activeSubscriptions.isEmpty ? "—" : "未加载"))
                    Divider()
                    InfoRow("更新方式", value: "应用下载后交给内核（file provider）")
                    Divider()
                    InfoRow("健康检查", value: "300 秒")
                }
            }

            Card(title: "高级：使用自己的配置", systemImage: "doc.text") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("留空则使用 MihomoBar 生成的配置",
                              text: $model.settings.customConfigPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    Text("指向你自己的 Clash 配置。该文件以只读方式传给内核，**绝不会被修改**。\n填写后上面的订阅列表会被忽略。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button {
                            model.revealDataDir()
                        } label: {
                            Label("打开数据目录", systemImage: "folder")
                        }
                        Button {
                            model.saveSettings(model.settings)
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        Spacer()
                    }
                    .controlSize(.regular)
                }
            }

            Card(title: "生成的文件", systemImage: "folder") {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow("生成配置", value: "generated.yaml", hint: "由应用写入，用户配置不受影响")
                    Divider()
                    InfoRow("订阅缓存", value: "data/providers/*.yaml")
                    Divider()
                    InfoRow("内核日志", value: "mihomo.log")
                }
            }
        }
    }

    // MARK: - Row

    private func subscriptionRow(_ sub: SubscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { sub.enabled },
                    set: { model.setSubscriptionEnabled(id: sub.id, enabled: $0) }
                )) {
                    Text(sub.name)
                        .font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 8)

                Text(nodeLabel(for: sub))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(sub.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button {
                    Task { await model.refreshSubscriptionRow(id: sub.id) }
                } label: {
                    if model.updatingSubscriptionID == sub.id && model.busy {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("更新中")
                        }
                    } else {
                        Label("更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(model.busy || !sub.isUsable)

                Button(role: .destructive) {
                    model.removeSubscription(id: sub.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(model.busy)

                Spacer()
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .opacity(sub.enabled ? 1 : 0.55)
    }

    private func nodeLabel(for sub: SubscriptionEntry) -> String {
        if let n = sub.lastNodeCount { return "\(n) 节点" }
        return sub.enabled ? "未更新" : "已停用"
    }
}
