import Foundation

/// 需要 root 的操作。
///
/// macOS 上 `networksetup -setwebproxy` 和 TUN 模式都需要管理员权限。
/// 这里用 `osascript ... with administrator privileges` 弹出一次系统授权框；
/// 优点是零签名成本、立刻可用，缺点是重启后需要重新授权一次。
///
/// 后续如果要免去反复授权，再换成 `SMAppService` 注册 LaunchDaemon helper
/// （Clash Verge 的做法）。接口保持不变即可平滑替换。
enum Privileged {

    /// 通过 osascript 以管理员身份执行一段 shell。
    /// 调用方负责把所有命令合并成一次调用，避免弹多次授权框。
    @discardableResult
    static func runShell(_ command: String) throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            if msg.contains("-128") { throw PrivilegedError.cancelled }
            throw PrivilegedError.failed(msg.isEmpty ? "退出码 \(p.terminationStatus)" : msg)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// 以管理员身份在**后台**启动一个进程，返回它的 pid。
    ///
    /// 两个关键细节（已实测验证）：
    ///
    /// 1. 后台进程的 stdout/stderr **必须重定向到文件**。否则它继承 osascript
    ///    的管道，`do shell script` 会一直阻塞到该进程退出才返回 —— 这是个静默的死锁。
    /// 2. 末尾的 `echo $!` 是唯一能从提权 shell 里拿回 pid 的方式。
    ///
    /// 提权进程在 `do shell script` 返回后会被 launchd 接管，与 GUI 生命周期解耦，
    /// 所以退出 GUI 不会连带杀死内核（这对 TUN 模式是必要的）。
    static func spawnAsRoot(executable: URL,
                            arguments: [String],
                            logPath: String,
                            workingDirectory: String? = nil) throws -> pid_t {
        let cmd = buildBackgroundCommand(executable: executable,
                                         arguments: arguments,
                                         logPath: logPath,
                                         workingDirectory: workingDirectory)
        let out = try runShell(cmd)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed) else {
            throw PrivilegedError.badPID(trimmed)
        }
        return pid
    }

    /// 拼出「以后台方式启动并回显 pid」的 shell 命令。
    ///
    /// 独立成函数是为了可测：自检会拿它跟一个无特权的 `sh -c` 跑一遍，
    /// 在不弹授权框的前提下验证整条机制。
    ///
    /// ⚠️ 整条命令（含 `cd`）**必须包在花括号里一起重定向**。
    /// 若只给最后一个命令加重定向，例如：
    ///
    ///     cd X && mihomo ... >> log 2>&1 &
    ///
    /// 后台子 shell 会继续持有调用方的 stdout，于是 `do shell script`（以及任何
    /// 读管道的一方）会阻塞到该进程退出为止 —— 对内核来说就是永远。
    /// 实测：这种写法耗时 30019 ms，包裹写法 9 ms。
    static func buildBackgroundCommand(executable: URL,
                                       arguments: [String],
                                       logPath: String,
                                       workingDirectory: String? = nil) -> String {
        var body = ""
        if let dir = workingDirectory {
            body += "cd \(shellQuote(dir)) && "
        }
        body += ([executable.path] + arguments).map(shellQuote).joined(separator: " ")
        return "{ \(body); } >> \(shellQuote(logPath)) 2>&1 < /dev/null & echo $!"
    }

    /// 给提权进程发信号。内核必须收到 SIGTERM 而不是 SIGKILL，
    /// 否则 TUN 模式会残留 utun 接口和路由。
    static func signal(_ pid: pid_t, _ sig: Int32) throws {
        try runShell("kill -\(sig) \(pid)")
    }

    /// 判断进程是否存活。
    ///
    /// 注意 `kill(pid, 0)` 对 root 进程会返回 EPERM —— 那表示**进程存在但无权发信号**，
    /// 而不是不存在。只有 ESRCH 才代表真正退出。
    static func processExists(_ pid: pid_t) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// POSIX shell 单引号转义
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum PrivilegedError: Error, CustomStringConvertible {
    case cancelled
    case failed(String)
    case badPID(String)

    var description: String {
        switch self {
        case .cancelled:        return "已取消授权"
        case .failed(let m):    return "提权执行失败：\(m.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .badPID(let s):    return "提权进程未返回有效 pid（返回内容：\(s.prefix(80))）"
        }
    }
}

/// 系统代理开关。读写都通过 `networksetup`，
/// 读不需要 root，写需要，所以只有写路径走 `Privileged`。
enum SystemProxy {

    /// 所有处于启用状态的网络服务名（不含被停用的，那些带 `*` 前缀）
    static func activeServices() -> [String] {
        guard let out = try? shell("/usr/sbin/networksetup -listallnetworkservices") else { return [] }
        return out.split(separator: "\n")
            .dropFirst()                                   // 首行是说明文字
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// 当前是否有任一服务开了 HTTP 代理指向 127.0.0.1
    static func isEnabled() -> Bool {
        for service in activeServices() {
            guard let out = try? shell("/usr/sbin/networksetup -getwebproxy \"\(service)\"") else { continue }
            var enabled = false, server = ""
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2 else { continue }
                if parts[0] == "Enabled" { enabled = (parts[1].lowercased() == "yes") }
                if parts[0] == "Server"  { server = parts[1] }
            }
            if enabled && (server == "127.0.0.1" || server == "localhost") { return true }
        }
        return false
    }

    /// 一次授权完成所有服务的开启：http + https + socks 指向本地内核。
    static func enable(port: Int, bypass: [String] = defaultBypass) throws {
        let services = activeServices()
        guard !services.isEmpty else { throw SystemProxyError.noService }

        var lines: [String] = []
        for s in services {
            let q = "\"\(s)\""
            lines += [
                "/usr/sbin/networksetup -setwebproxy \(q) 127.0.0.1 \(port)",
                "/usr/sbin/networksetup -setsecurewebproxy \(q) 127.0.0.1 \(port)",
                "/usr/sbin/networksetup -setsocksfirewallproxy \(q) 127.0.0.1 \(port)",
                "/usr/sbin/networksetup -setproxybypassdomains \(q) \(bypass.joined(separator: " "))",
            ]
        }
        // 合并成一条 shell，只弹一次密码框
        try Privileged.runShell(lines.joined(separator: " && "))
    }

    static func disable() throws {
        let services = activeServices()
        guard !services.isEmpty else { throw SystemProxyError.noService }

        var lines: [String] = []
        for s in services {
            let q = "\"\(s)\""
            lines += [
                "/usr/sbin/networksetup -setwebproxystate \(q) off",
                "/usr/sbin/networksetup -setsecurewebproxystate \(q) off",
                "/usr/sbin/networksetup -setsocksfirewallproxystate \(q) off",
            ]
        }
        try Privileged.runShell(lines.joined(separator: " && "))
    }

    /// 本机/局域网地址不走代理，否则会出现回环问题
    static let defaultBypass = [
        "127.0.0.1", "localhost", "::1",
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "169.254.0.0/16", "*.local",
    ]

    /// 不需要提权的小工具
    private static func shell(_ command: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum SystemProxyError: Error, CustomStringConvertible {
    case noService

    var description: String {
        switch self {
        case .noService: return "没有找到启用的网络服务"
        }
    }
}
