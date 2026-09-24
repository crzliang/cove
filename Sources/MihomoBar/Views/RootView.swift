import SwiftUI

/// 菜单栏弹出面板。
///
/// 有意保持精简：复杂 UI（完整节点列表、规则、连接、流量曲线）
/// 由内核自带的 MetaCubeXD 在浏览器里提供，点「面板」即可。
/// 这里只放每天真正会用到的那几个开关。
struct RootView: View {

    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    if model.needsRestart {
                        restartHint
                    }
                    if model.status.isRunning && !model.groups.isEmpty {
                        Divider()
                        groupsSection
                    }
                    Divider()
                    actions
                    if model.showLog { logSection }
                    if model.showSettings { settingsSection }
                    if let banner = model.banner { bannerView(banner) }
                }
                .padding(14)
            }
        }
        .frame(width: 400, height: 560)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text("MihomoBar").font(.headline)
                    Text(model.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.kernel.isPrivileged {
                        Text("root")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                Text(model.versionLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button {
                model.showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
        .padding(12)
    }

    private var statusColor: Color {
        switch model.status {
        case .running:              return .green
        case .starting, .stopping:  return .orange
        case .stopped:              return .secondary
        case .failed:               return .red
        }
    }

    // MARK: - 主开关

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                set: { on in Task { await model.setSystemProxy(on) } }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("系统代理")
                    Text("需要管理员授权 · 127.0.0.1:\(String(model.settings.mixedPort))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!model.status.isRunning || model.busy)

            if !model.settings.subscriptionURL.isEmpty && model.settings.customConfigPath.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(model.providerInfo ?? "订阅加载中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即更新") {
                        Task { await model.refreshSubscription() }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .disabled(!model.status.isRunning || model.busy)
                }
            }

            HStack(spacing: 6) {
                Text("模式").font(.callout)
                Picker("", selection: Binding(
                    get: { model.mode },
                    set: { m in Task { await model.setMode(m) } }
                )) {
                    Text("规则").tag("rule")
                    Text("全局").tag("global")
                    Text("直连").tag("direct")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.status.isRunning || model.busy)
            }
        }
    }

    private var restartHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("设置已改，需重启内核生效")
                .font(.caption)
            Spacer()
            Button("重启") {
                Task {
                    await model.toggleKernel()
                    await model.startKernel()
                }
            }
            .font(.caption)
            .disabled(model.busy || model.status.isBusy)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 策略组

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("策略组")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        model.expandedGroup = (model.expandedGroup == group.id) ? nil : group.id
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.expandedGroup == group.id
                                  ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(group.name).font(.callout)
                            Spacer()
                            Text(group.now)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let d = group.delay {
                                Text("\(d)ms")
                                    .font(.caption2)
                                    .foregroundStyle(delayColor(d))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if model.expandedGroup == group.id {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(group.options.prefix(60), id: \.self) { node in
                                Button {
                                    Task { await model.select(group: group.id, node: node) }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: node == group.now
                                              ? "checkmark.circle.fill" : "circle")
                                            .font(.caption2)
                                            .foregroundStyle(node == group.now
                                                             ? Color.accentColor : .secondary)
                                        Text(node)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 1)
                                }
                                .buttonStyle(.plain)
                            }
                            if group.options.count > 60 {
                                Text("… 还有 \(group.options.count - 60) 个节点，请到面板查看")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 18)
                    }
                }
            }
        }
    }

    private func delayColor(_ ms: Int) -> Color {
        if ms <= 0 { return .red }
        if ms < 150 { return .green }
        if ms < 400 { return .orange }
        return .red
    }

    // MARK: - 操作

    private var actions: some View {
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

            HStack(spacing: 8) {
                Button {
                    model.showLog.toggle()
                } label: {
                    Label("日志", systemImage: "doc.text").frame(maxWidth: .infinity)
                }
                Button {
                    model.revealDataDir()
                } label: {
                    Label("数据目录", systemImage: "folder").frame(maxWidth: .infinity)
                }
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("退出 MihomoBar").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
        .controlSize(.regular)
    }

    // MARK: - 日志

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("内核日志（最后 120 行）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { model.refreshLog() }
                    .font(.caption2)
                    .buttonStyle(.borderless)
            }
            ScrollView {
                Text(model.logTail)
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    // MARK: - 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设置")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("订阅链接") {
                TextField("https://…", text: $model.settings.subscriptionURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Text("留空则只提供本地端口，不做分流。填写后由内核按 interval 自行刷新。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            LabeledContent("混合端口") {
                TextField("7890", value: $model.settings.mixedPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            LabeledContent("自定义配置") {
                TextField("留空则使用生成的配置", text: $model.settings.customConfigPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Text("指向你自己的 Clash 配置。该文件只读传入内核，绝不会被修改。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Toggle(isOn: $model.settings.tunEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("TUN 模式")
                    Text("启动内核时会请求管理员授权，以 root 运行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { on in Task { await model.setLaunchAtLogin(on) } }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("开机自启")
                    Text(LaunchAtLogin.statusDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!LaunchAtLogin.isAvailable)

            HStack {
                Spacer()
                Button("保存") {
                    model.saveSettings(model.settings)
                    model.showSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 提示条

    private func bannerView(_ banner: AppModel.Banner) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .blue)
            Text(banner.text)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background((banner.isError ? Color.orange : Color.blue).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
