import Foundation
import HelperProtocol

/// 特权助手的安装与卸载。
///
/// **整个设计的关键点：只在安装时授权一次。**
/// 装好之后助手由 launchd 以 root 常驻，所有特权操作（TUN 内核、系统代理）
/// 都走 socket，不再触发任何授权框 —— 不管指纹还是密码都不会再问。
///
/// 之所以不用 `SMAppService.daemon`：它要求应用带 Apple 开发者证书签名
/// （需要 Team Identifier）。实测用自签名证书会返回
/// `SMAppServiceErrorDomain Code=1 "Operation not permitted"`。
/// 这里改走传统路径：把二进制装到 /Library/PrivilegedHelperTools，
/// 把 plist 装到 /Library/LaunchDaemons，再用 launchctl 加载 ——
/// 效果完全一样，且不挑签名。
enum HelperInstaller {

    /// 助手二进制是否已就位
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Helper.installedPath)
    }

    /// 助手是否正在运行（能应答 ping）
    static var isRunning: Bool {
        guard isInstalled else { return false }
        var req = Helper.Request(cmd: .ping)
        req.protocolVersion = Helper.protocolVersion
        return (try? HelperSocket.call(req)) != nil
    }

    /// 在 app bundle 里找到助手二进制
    static func bundledHelperPath() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        let candidates = [
            dir.appendingPathComponent("MihomoBarHelper"),
            dir.deletingLastPathComponent().appendingPathComponent("MacOS/MihomoBarHelper"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - 安装

    /// 安装助手。**会弹一次系统授权框**（支持触控 ID），之后永不再弹。
    @discardableResult
    static func install() throws -> String {
        guard let source = bundledHelperPath() else {
            throw HelperInstallError.helperBinaryMissing
        }

        // 先把 plist 写到用户可写的位置，再由提权 shell 拷进 /Library
        try Paths.ensureDirs()
        let staging = Paths.root.appendingPathComponent("\(Helper.label).plist")
        try launchDaemonPlist().write(to: staging, atomically: true, encoding: .utf8)

        let q = Privileged.shellQuote
        let commands = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -m 755 -o root -g wheel \(q(source.path)) \(q(Helper.installedPath))",
            "/usr/bin/install -m 644 -o root -g wheel \(q(staging.path)) \(q(Helper.plistPath))",
            // 已加载时先卸掉，保证重复安装幂等
            "/bin/launchctl bootout system/\(Helper.label) >/dev/null 2>&1 || true",
            "/bin/launchctl enable system/\(Helper.label)",
            "/bin/launchctl bootstrap system \(q(Helper.plistPath))",
        ]
        try Privileged.runBatch(commands)

        // 给 launchd 一点时间把进程拉起来，并捕获失败原因。
        // 实测 `launchctl bootstrap` 到 socket 可连有时要好几秒，
        // 窗口太短会误报「装好了但连不上」。
        var lastError: String?
        for _ in 0..<60 {
            var req = Helper.Request(cmd: .ping)
            req.protocolVersion = Helper.protocolVersion
            do {
                _ = try HelperSocket.call(req)
                return "助手已安装并运行"
            } catch {
                lastError = String(describing: error)
                usleep(250_000)
            }
        }
        throw HelperInstallError.didNotStart(lastError)
    }

    /// 卸载助手（需要授权，因为要删 /Library 下的文件）
    static func uninstall() throws {
        if isRunning {
            var req = Helper.Request(cmd: .uninstall)
            req.protocolVersion = Helper.protocolVersion
            _ = try? HelperSocket.call(req)
            // 助手会自行退出，等它把文件清掉
            for _ in 0..<20 {
                if !isInstalled { break }
                usleep(150_000)
            }
            if !isInstalled { return }
        }
        // 助手没响应或没清干净，退回到提权 shell
        let q = Privileged.shellQuote
        try Privileged.runBatch([
            "/bin/launchctl bootout system/\(Helper.label) >/dev/null 2>&1 || true",
            "/bin/launchctl disable system/\(Helper.label) >/dev/null 2>&1 || true",
            "/bin/rm -f \(q(Helper.plistPath)) \(q(Helper.installedPath))",
            "/bin/rmdir \(q(Helper.socketDirectory)) >/dev/null 2>&1 || true",
        ])
    }

    // MARK: - launchd 配置

    private static func launchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Helper.label)</string>
            <key>Program</key>
            <string>\(Helper.installedPath)</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardErrorPath</key>
            <string>/var/log/\(Helper.label).stderr.log</string>
        </dict>
        </plist>
        """
    }

    /// 提权内核副本是否已是最新 —— 即 `stageKernelForHelper()` 不需要重新安装。
    ///
    /// 存在的意义：重新安装要走 `osascript ... with administrator privileges`，
    /// 会**弹授权框**。非交互场景（自检、脚本）里那等于挂死，所以调用方要先问一下。
    static func kernelStagingIsCurrent() -> Bool {
        guard let source = try? Bundled.ensureKernel() else { return false }
        let destination = "\(Helper.socketDirectory)/mihomo"
        let fm = FileManager.default
        guard let src = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date,
              let dst = (try? fm.attributesOfItem(atPath: destination)[.modificationDate]) as? Date
        else { return false }
        return dst >= src && !needsQuarantineClear(destination)
    }

    /// 检查文件是否带 Gatekeeper 隔离属性。
    /// 普通用户进程可以读 root 文件上的扩展属性，所以这里不需要提权。
    static func needsQuarantineClear(_ path: String) -> Bool {
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
        return size >= 0
    }

    /// 内核二进制也放到助手目录，让助手能以 root 直接执行。
    ///
    /// 内核在 Application Support 里只有当前用户可写，root 虽然能读，
    /// 但把「以 root 执行的可执行文件」放在用户可写的位置本身就是个隐患 ——
    /// 任何能写那个目录的进程都能替换掉内核，从而获得 root 执行。
    /// 所以提权模式下用一份放在 root 专属目录里的副本。
    ///
    /// 已装助手时**只**走 `stageKernel`（root、不弹框）。osascript 密码框
    /// 不支持触控 ID，所以绝不再在「助手已装」时用它更新内核。
    static func stageKernelForHelper() throws -> String {
        guard let source = try? Bundled.ensureKernel() else {
            throw HelperInstallError.kernelMissing
        }
        let destination = "\(Helper.socketDirectory)/mihomo"
        let fm = FileManager.default
        let upToDate: Bool = {
            guard let src = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date,
                  let dst = (try? fm.attributesOfItem(atPath: destination)[.modificationDate]) as? Date
            else { return false }
            return dst >= src
        }()

        if upToDate && !needsQuarantineClear(destination) {
            return destination
        }

        if isInstalled {
            var req = Helper.Request(cmd: .stageKernel)
            req.protocolVersion = Helper.protocolVersion
            req.kernelSource = source.path
            do {
                _ = try HelperSocket.call(req)
                return destination
            } catch {
                throw HelperInstallError.helperOutdated(String(describing: error))
            }
        }

        // 未装助手时的降级（TUN 正常不会走到这里）
        let q = Privileged.shellQuote
        try Privileged.runBatch([
            "/bin/mkdir -p \(q(Helper.socketDirectory))",
            "/usr/bin/install -m 755 -o root -g wheel \(q(source.path)) \(q(destination))",
            "{ /usr/bin/xattr -d com.apple.quarantine \(q(destination)) 2>/dev/null || true; }",
        ])
        return destination
    }
}

enum HelperInstallError: Error, CustomStringConvertible {
    case helperBinaryMissing
    case didNotStart(String?)
    case kernelMissing
    case helperOutdated(String)

    var description: String {
        switch self {
        case .helperBinaryMissing:
            return "app 里找不到 MihomoBarHelper。请用 scripts/bundle.sh 重新打包。"
        case .didNotStart(let detail):
            return "助手已安装但连不上：\(detail ?? "超时")\n"
                 + "请检查 /var/log/\(Helper.label).helper.log 与 .stderr.log"
        case .kernelMissing:
            return "找不到 mihomo 内核"
        case .helperOutdated(let detail):
            return "特权助手版本过旧，无法免密更新内核（\(detail)）。\n"
                 + "请到设置里点「重新安装」助手（只需再授权一次）。"
        }
    }
}
