import Foundation
import HelperProtocol

/// 助手安装/卸载的命令行入口。
///
/// 存在的意义是**可测**：GUI 里点按钮没问题，但自动化验证需要能在无界面下
/// 走完「安装 → ping → 卸载」全流程。
///
///     Cove --install-helper
///     Cove --uninstall-helper
///     Cove --helper-status
enum HelperCLI {

    static func run(_ args: [String]) -> Bool {
        if args.contains("--install-helper") {
            install(); return true
        }
        if args.contains("--uninstall-helper") {
            uninstall(); return true
        }
        if args.contains("--helper-status") {
            status(); return true
        }
        return false
    }

    private static func install() {
        print("安装特权助手到 \(Helper.installedPath)")
        print("（会弹一次系统授权，可用触控 ID）")
        do {
            _ = try HelperInstaller.install()
            print("✅ 安装完成")
            status()
        } catch {
            print("❌ \(error)")
            exit(1)
        }
    }

    private static func uninstall() {
        print("卸载特权助手")
        do {
            try HelperInstaller.uninstall()
            print("✅ 已卸载")
        } catch {
            print("❌ \(error)")
            exit(1)
        }
    }

    private static func status() {
        print("── 助手状态 ──────────────────────────")
        print("  二进制：\(Helper.installedPath)")
        print("  已安装：\(HelperInstaller.isInstalled ? "是" : "否")")
        print("  运行中：\(HelperInstaller.isRunning ? "是" : "否")")
        print("  socket：\(Helper.socketPath)")
        print("  plist ：\(Helper.plistPath)")
        if FileManager.default.fileExists(atPath: Helper.plistPath) {
            print("  launchd 配置已就位")
        }
        if let log = try? String(contentsOfFile: "/var/log/\(Helper.label).helper.log",
                                 encoding: .utf8) {
            print("── 助手日志尾部 ──────────────────────")
            print(log.split(separator: "\n").suffix(8).joined(separator: "\n"))
        }
    }
}
