import SwiftUI
import AppKit

/// 订阅：顶部一条链接，下面是两列卡片。
///
/// 点哪张卡片就切到哪条订阅（同时只能启用一条）；蓝框标「当前」。
struct SubscriptionPane: View {
    @ObservedObject var model: AppModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280, maximum: 520), spacing: 12)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            importBar
            if !model.canEditCustomRules {
                customConfigBanner
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.settings.subscriptions.isEmpty {
                        Text("还没有订阅。把链接贴到上面，点「导入」。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.settings.subscriptions) { sub in
                                subscriptionCard(sub)
                            }
                        }
                    }
                    customConfigCard
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: Binding(
            get: { model.editingSubscriptionID != nil },
            set: { if !$0 { model.cancelEditSubscription() } }
        )) {
            EditSubscriptionSheet(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("订阅")
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            Button {
                Task { await model.refreshSubscription() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.busy || model.settings.activeSubscriptions.isEmpty)
            .help("更新全部启用中的订阅")
        }
    }

    private var importBar: some View {
        HStack(spacing: 8) {
            TextField("订阅文件链接", text: $model.draftSubURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            Button {
                pasteURL()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .help("粘贴剪贴板里的链接")
            Button {
                let url = model.draftSubURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let host = URL(string: url)?.host
                Task { await model.addSubscription(name: host ?? "", url: url) }
            } label: {
                if model.busy && model.updatingSubscriptionID == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text("导入")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.draftSubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.regular)
    }

    private var customConfigBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("当前使用自定义配置文件，上面的订阅不会参与生成配置。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func subscriptionCard(_ sub: SubscriptionEntry) -> some View {
        let updating = model.updatingSubscriptionID == sub.id && model.busy
        let hasURL = !sub.trimmedURL.isEmpty
        return Button {
            guard !model.busy else { return }
            Task { await model.activateSubscription(id: sub.id) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(sub.enabled ? Color.accentColor : Color.secondary)
                    Text(sub.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(sub.enabled ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if sub.enabled {
                        Text("当前")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    Button {
                        Task { await model.refreshSubscriptionRow(id: sub.id) }
                    } label: {
                        if updating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.busy || !hasURL)
                    .help("更新这条订阅")

                    Menu {
                        Button("编辑") {
                            model.beginEditSubscription(id: sub.id)
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            model.removeSubscription(id: sub.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 16)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(model.busy)
                }

                HStack(spacing: 8) {
                    Text(hostText(sub))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(timeText(sub))
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Text(usageText(sub))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                usageBar(sub)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(sub.enabled ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: sub.enabled ? 1.5 : 0.5)
            )
            .opacity(sub.enabled ? 1 : 0.72)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(sub.enabled ? "当前使用的订阅" : "点按切换到这条订阅")
    }

    private func usageBar(_ sub: SubscriptionEntry) -> some View {
        let fraction = usageFraction(sub)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }

    private var customConfigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("使用自己的配置")
                .font(.system(size: 13, weight: .semibold))
            TextField("留空则使用上面的订阅生成配置", text: $model.settings.customConfigPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Text("指向一份 Clash 配置。该文件只读传给内核，填写后订阅列表不再参与生成。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    model.revealDataDir()
                } label: {
                    Label("数据目录", systemImage: "folder")
                }
                Button {
                    model.saveSettings(model.settings)
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func pasteURL() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        model.draftSubURL = text
    }

    private func hostText(_ sub: SubscriptionEntry) -> String {
        if let host = URL(string: sub.trimmedURL)?.host, !host.isEmpty { return host }
        return sub.trimmedURL.isEmpty ? "没有链接" : sub.trimmedURL
    }

    private func timeText(_ sub: SubscriptionEntry) -> String {
        guard let date = sub.updatedAt else { return "未更新" }
        return Self.relative.localizedString(for: date, relativeTo: Date())
    }

    private func usageText(_ sub: SubscriptionEntry) -> String {
        if let total = sub.trafficTotal, total > 0 {
            let used = (sub.trafficUpload ?? 0) + (sub.trafficDownload ?? 0)
            return "\(Self.quota(used)) / \(Self.quota(total))"
        }
        if let count = sub.lastNodeCount { return "\(count) 个节点" }
        return "尚未更新"
    }

    private func usageFraction(_ sub: SubscriptionEntry) -> Double {
        guard let total = sub.trafficTotal, total > 0 else { return 0 }
        let used = Double((sub.trafficUpload ?? 0) + (sub.trafficDownload ?? 0))
        return min(1, used / Double(total))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    /// 149GB、6.37GB 这种紧凑写法，数字和单位之间不留空格。
    private static func quota(_ bytes: Int) -> String {
        let value = Double(max(0, bytes))
        let gb = value / 1_073_741_824
        if gb >= 100 { return String(format: "%.0fGB", gb) }
        if gb >= 10 { return String(format: "%.1fGB", gb) }
        if gb >= 1 { return String(format: "%.2fGB", gb) }
        let mb = value / 1_048_576
        if mb >= 100 { return String(format: "%.0fMB", mb) }
        if mb >= 10 { return String(format: "%.1fMB", mb) }
        if mb >= 1 { return String(format: "%.2fMB", mb) }
        let kb = value / 1024
        if kb >= 1 { return String(format: "%.0fKB", kb) }
        return "\(bytes)B"
    }
}

private struct EditSubscriptionSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑订阅")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                labeled("名称") {
                    TextField("可选，如「机场 A」", text: $model.editSubName)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("链接") {
                    TextField("https://…", text: $model.editSubURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("改链接后会立刻重新下载；只改名称不会触发更新。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelEditSubscription()
                }
                .keyboardShortcut(.cancelAction)
                Button("保存") {
                    Task { await model.saveEditSubscription() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.editSubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.busy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func labeled<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
