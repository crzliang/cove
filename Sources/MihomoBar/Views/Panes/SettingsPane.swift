import SwiftUI
import AppKit
import HelperProtocol

/// 设置：按用途分组。
struct SettingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PaneScaffold(title: "设置", subtitle: "改动后需重启内核生效的项目会单独提示") {
            kernelCard
            networkCard
            systemCard
            helperCard
            aboutCard
        }
    }

    // MARK: - 内核

    private var kernelCard: some View {
        Card(title: "内核", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 12) {
                InfoRow("版本", value: model.versionLine)
                Divider()
                InfoRow("混合端口", hint: "HTTP / SOCKS 共用，也是系统代理指向的端口") {
                    TextField("", value: $model.settings.mixedPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .font(.system(size: 12))
                }
                Divider()
                InfoRow("日志级别", hint: "debug 会明显增大日志量") {
                    Picker("", selection: $model.settings.logLevel) {
                        Text("error").tag("error")
                        Text("warning").tag("warning")
                        Text("info").tag("info")
                        Text("debug").tag("debug")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                Divider()
                HStack {
                    Button {
                        model.saveSettings(model.settings)
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        Task { await model.startKernel() }
                    } label: {
                        Label("重启内核", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.busy || model.status.isBusy)
                    Spacer()
                }
                .controlSize(.regular)
            }
        }
    }

    // MARK: - 网络

    private var networkCard: some View {
        Card(title: "网络", systemImage: "network") {
            VStack(alignment: .leading, spacing: 12) {
                InfoRow("TUN 模式",
                        hint: "以 root 运行内核并接管全部流量。需要特权助手。") {
                    Toggle("", isOn: $model.settings.tunEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!model.helperInstalled)
                }
                if !model.helperInstalled {
                    Label("需先安装下方的特权助手", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Divider()
                InfoRow("系统代理", hint: "修改各网络服务的 HTTP / HTTPS / SOCKS 代理设置") {
                    Text(model.systemProxyOn ? "已开启" : "已关闭")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(model.systemProxyOn ? .green : .secondary)
                }
                if model.systemProxyOn {
                    Button {
                        Task { await model.setSystemProxy(false) }
                    } label: {
                        Label("关闭系统代理", systemImage: "xmark.circle")
                    }
                    .controlSize(.regular)
                } else {
                    Button {
                        Task { await model.setSystemProxy(true) }
                    } label: {
                        Label("开启系统代理", systemImage: "checkmark.circle")
                    }
                    .controlSize(.regular)
                    .disabled(!model.status.isRunning)
                }
            }
        }
    }

    // MARK: - 系统集成

    private var systemCard: some View {
        Card(title: "系统集成", systemImage: "gearshape.2") {
            VStack(alignment: .leading, spacing: 12) {
                InfoRow("开机自启", hint: LaunchAtLogin.statusDescription) {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { on in Task { await model.setLaunchAtLogin(on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!LaunchAtLogin.isAvailable)
                }
                Divider()
                InfoRow("启动时打开窗口", hint: "开机自启时建议关闭，避免每次登录都弹窗") {
                    Toggle("", isOn: $model.settings.showWindowOnLaunch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Divider()
                InfoRow("在 Dock 中显示", hint: "关掉后退化为纯菜单栏应用") {
                    Toggle("", isOn: $model.settings.showInDock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Divider()
                HStack {
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
    }

    // MARK: - 特权助手

    private var helperCard: some View {
        Card(title: "特权助手", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusDot(level: model.helperRunning ? .ok : (model.helperInstalled ? .warn : .off))
                    Text(model.helperRunning
                         ? "已安装并运行"
                         : (model.helperInstalled ? "已安装但未运行" : "未安装"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }

                Text("""
                助手是以 root 身份常驻的后台服务，负责需要管理员权限的操作：TUN 模式、系统代理开关。

                没有它时，每次这类操作都会弹出系统授权框。安装它只需要授权**一次**，之后就再也不会打扰你。
                """)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.helperInstalled {
                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow("二进制", value: Helper.installedPath)
                        InfoRow("launchd 配置", value: Helper.plistPath)
                        InfoRow("控制 socket", value: Helper.socketPath)
                    }
                }

                HStack(spacing: 8) {
                    if model.helperRunning {
                        Button(role: .destructive) {
                            Task { await model.uninstallHelper() }
                        } label: {
                            Label("卸载助手", systemImage: "trash")
                        }
                    } else {
                        Button {
                            Task { await model.installHelper() }
                        } label: {
                            Label("安装助手", systemImage: "lock.shield")
                        }
                    }
                    if model.helperInstalled {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: "/var/log/\(Helper.label).helper.log")])
                        } label: {
                            Label("查看助手日志", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    Spacer()
                }
                .controlSize(.regular)
                .disabled(model.busy)
            }
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        Card(title: "关于", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 10) {
                InfoRow("数据目录", value: Paths.root.path)
                Divider()
                InfoRow("内核", value: Paths.kernelBinary.path)
                Divider()
                InfoRow("", hint: "MihomoBar 以子进程方式运行 mihomo，不链接其代码，因此不受 GPL-3.0 影响。",
                        trailing: { EmptyView() }
                )
                HStack {
                    Button {
                        model.revealDataDir()
                    } label: {
                        Label("打开数据目录", systemImage: "folder")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/MetaCubeX/mihomo")!)
                    } label: {
                        Label("mihomo 项目主页", systemImage: "safari")
                    }
                    Spacer()
                }
                .controlSize(.regular)
            }
        }
    }
}
