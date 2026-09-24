import SwiftUI

/// 订阅：链接管理 + 拉取状态。
struct SubscriptionPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PaneScaffold(title: "订阅", subtitle: "填入 Clash / Mihomo 订阅链接，内核会按间隔自动刷新") {
            Card(title: "订阅链接", systemImage: "link") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://example.com/subscribe?token=…",
                              text: $model.settings.subscriptionURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    HStack(spacing: 8) {
                        Button {
                            model.saveSettings(model.settings)
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            Task { await model.refreshSubscription() }
                        } label: {
                            if model.busy {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.small)
                                    Text("更新中…")
                                }
                            } else {
                                Label("立即更新", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(model.busy || !model.status.isRunning
                                  || model.settings.subscriptionURL.isEmpty)
                        .help(model.status.isRunning ? "" : "需要先启动内核")

                        Spacer()

                        if !model.settings.subscriptionURL.isEmpty {
                            Button(role: .destructive) {
                                model.settings.subscriptionURL = ""
                                model.saveSettings(model.settings)
                            } label: {
                                Label("清除", systemImage: "trash")
                            }
                        }
                    }
                    .controlSize(.regular)
                }
            }

            Card(title: "拉取状态", systemImage: "info.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    InfoRow("节点数", value: model.providerInfo ?? "—")
                    Divider()
                    InfoRow("刷新间隔", value: "3600 秒（内核自动）")
                    Divider()
                    InfoRow("健康检查", value: "300 秒")
                    InfoRow("", hint: "内核会自行按间隔拉取订阅并对节点做健康检查，应用侧不需要保持运行。",
                            trailing: { EmptyView() })
                }
            }

            Card(title: "高级：使用自己的配置", systemImage: "doc.text") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("留空则使用 MihomoBar 生成的配置",
                              text: $model.settings.customConfigPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    Text("指向你自己的 Clash 配置。该文件以只读方式传给内核，**绝不会被修改**。\n填写后上面的订阅设置会被忽略。")
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
                    InfoRow("内核日志", value: "mihomo.log")
                    Divider()
                    InfoRow("运行信息", value: "runtime.json", hint: "当前端口与 secret")
                }
            }
        }
    }
}
