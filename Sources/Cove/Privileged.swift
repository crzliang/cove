import Foundation
import Security
import Darwin
import HelperProtocol

/// 需要 root 的操作。
///
/// **常态路径是特权助手**（见 `HelperInstaller`）：一次授权安装，之后零弹框。
/// 这里的提权只用于两件事：
/// 1. 安装/卸载助手本身
/// 2. 助手尚未安装（或过旧不支持 stageKernel）时的降级路径
///
/// 提权走 Authorization Services（`AuthorizationExecuteWithPrivileges`），
/// 系统授权框支持触控 ID；**不要**用 `osascript … with administrator privileges`，
/// 那个框只能输密码。
enum Privileged {

    /// 以管理员身份执行一段 shell，返回 stdout。
    /// 调用方负责把所有命令合并成一次调用，避免弹多次授权框。
    @discardableResult
    static func runShell(_ command: String) throws -> String {
        try runAuthorized(tool: "/bin/sh", arguments: ["-c", command])
    }

    /// Authorization Services 提权执行，弹出可指纹认证的系统框。
    @discardableResult
    static func runAuthorized(tool: String, arguments: [String]) throws -> String {
        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authRef)
        guard createStatus == errAuthorizationSuccess, let auth = authRef else {
            throw PrivilegedError.failed("AuthorizationCreate 失败（\(createStatus)）")
        }
        defer { AuthorizationFree(auth, [.destroyRights]) }

        let rightsStatus: OSStatus = kAuthorizationRightExecute.withCString { namePtr in
            var item = AuthorizationItem(
                name: namePtr,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                return AuthorizationCopyRights(auth, &rights, nil, flags, nil)
            }
        }
        guard rightsStatus == errAuthorizationSuccess else {
            if rightsStatus == errAuthorizationCanceled { throw PrivilegedError.cancelled }
            throw PrivilegedError.failed("授权失败（\(rightsStatus)）")
        }

        guard let execute = authorizationExecuteWithPrivileges else {
            throw PrivilegedError.failed("系统不支持 AuthorizationExecuteWithPrivileges")
        }

        let argPtrs: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for p in argPtrs where p != nil { free(p) } }

        var pipe: UnsafeMutablePointer<FILE>?
        let toolPath = tool
        let execStatus: OSStatus = toolPath.withCString { pathPtr in
            var argv = argPtrs
            return argv.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else {
                    return OSStatus(errAuthorizationInternal)
                }
                return execute(auth, pathPtr, [], base, &pipe)
            }
        }
        guard execStatus == errAuthorizationSuccess else {
            if execStatus == errAuthorizationCanceled { throw PrivilegedError.cancelled }
            throw PrivilegedError.failed("提权执行失败（\(execStatus)）")
        }

        var output = Data()
        if let pipe {
            defer { fclose(pipe) }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = fread(&buffer, 1, buffer.count, pipe)
                if n > 0 { output.append(contentsOf: buffer.prefix(n)) }
                if n < buffer.count { break }
            }
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    /// 已从公开头文件移除，但仍在 Security.framework 里；用 dlsym 取出。
    private static let authorizationExecuteWithPrivileges: AuthorizationExecuteWithPrivilegesFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                              "AuthorizationExecuteWithPrivileges")
        else { return nil }
        return unsafeBitCast(sym, to: AuthorizationExecuteWithPrivilegesFn.self)
    }()

    private typealias AuthorizationExecuteWithPrivilegesFn = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    /// 以管理员身份在**后台**启动一个进程，返回它的 pid。
    ///
    /// 两个关键细节（已实测验证）：
    ///
    /// 1. 后台进程的 stdout/stderr **必须重定向到文件**。否则它继承提权
    ///    管道，`runShell` 会一直阻塞到该进程退出才返回 —— 这是个静默的死锁。
    /// 2. 末尾的 `echo $!` 是唯一能从提权 shell 里拿回 pid 的方式。
    ///
    /// 提权进程在命令返回后会被 launchd 接管，与 GUI 生命周期解耦，
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
    /// 后台子 shell 会继续持有调用方的 stdout，于是读管道的一方
    /// 会阻塞到该进程退出为止 —— 对内核来说就是永远。
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

    /// 一次性完成多个需要 root 的动作，**只弹一次授权框**。
    ///
    /// 安装助手、以及未装助手时的系统代理降级路径都要用这个 ——
    /// 分开调用会弹好几次框。
    static func runBatch(_ commands: [String]) throws {
        let script = commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " && ")
        guard !script.isEmpty else { return }
        try runShell(script)
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

    /// 进程常驻内存（RSS，字节）。对 root 内核也可用，不依赖 mihomo `/memory`。
    ///
    /// mihomo 的 `/connections.memory` 与 `/memory` WebSocket 在部分构建上恒为 0；
    /// `proc_pidinfo` 对 root 进程会返回失败，所以这里走 `ps`（普通用户可读 RSS）。
    static func residentBytes(of pid: pid_t) -> Int? {
        guard pid > 0 else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let kb = Int(text), kb > 0 else { return nil }
        return kb * 1024
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

    /// 开关系统代理。
    ///
    /// 装了助手就走 socket（零弹框）；没装则降级到 Authorization Services（弹一次授权框，可指纹）。
    static func set(enabled: Bool, port: Int) throws {
        if HelperInstaller.isInstalled {
            var req = Helper.Request(cmd: .setSystemProxy)
            req.protocolVersion = Helper.protocolVersion
            req.enabled = enabled
            req.port = port
            _ = try HelperSocket.call(req)
            return
        }
        try legacySet(enabled: enabled, port: port)
    }

    /// 降级路径：一次性把各服务的改动合并成一条 shell，只弹一次授权框。
    private static func legacySet(enabled: Bool, port: Int) throws {
        let services = activeServices()
        guard !services.isEmpty else { throw SystemProxyError.noService }

        var lines: [String] = []
        for s in services {
            let q = "\"\(s)\""
            if enabled {
                lines += [
                    "/usr/sbin/networksetup -setwebproxy \(q) 127.0.0.1 \(port)",
                    "/usr/sbin/networksetup -setsecurewebproxy \(q) 127.0.0.1 \(port)",
                    "/usr/sbin/networksetup -setsocksfirewallproxy \(q) 127.0.0.1 \(port)",
                    "/usr/sbin/networksetup -setproxybypassdomains \(q) \(defaultBypass.joined(separator: " "))",
                ]
            } else {
                lines += [
                    "/usr/sbin/networksetup -setwebproxystate \(q) off",
                    "/usr/sbin/networksetup -setsecurewebproxystate \(q) off",
                    "/usr/sbin/networksetup -setsocksfirewallproxystate \(q) off",
                ]
            }
        }
        try Privileged.runBatch(lines)
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

/// TUN 模式下把系统 DNS 指到 fake-ip 网关 `198.18.0.1`。
///
/// 不能改成 `119.29.29.29` 再靠 dns-hijack：macOS scoped DNS 会绕过 TUN，
/// 直接问真实 DNSPod，国外站又拿到污染 IP。`198.18.0.1` 是 utun 本机地址，
/// 解析器会直接问 mihomo。内核上游 DNS 另配，并排除出 TUN，避免打环。
enum SystemDNS {
    private static let backupURL =
        Paths.root.appendingPathComponent("dns.backup.json")
    private static let tunDNS = "198.18.0.1"

    static func applyTunDNS() {
        let services = SystemProxy.activeServices()
        guard !services.isEmpty else { return }

        if !FileManager.default.fileExists(atPath: backupURL.path) {
            var backup: [String: [String]] = [:]
            for service in services {
                backup[service] = currentServers(service)
            }
            if let data = try? JSONSerialization.data(withJSONObject: backup) {
                try? data.write(to: backupURL, options: .atomic)
            }
        }

        for service in services {
            _ = try? shell("/usr/sbin/networksetup -setdnsservers "
                           + quote(service) + " \(tunDNS)")
        }
        flushCache()
    }

    static func restore() {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return }

        let services = SystemProxy.activeServices()
        var backup: [String: [String]] = [:]
        if let data = try? Data(contentsOf: backupURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            backup = obj
        }
        try? FileManager.default.removeItem(at: backupURL)

        for service in services {
            let servers = backup[service] ?? []
            if servers.isEmpty {
                _ = try? shell("/usr/sbin/networksetup -setdnsservers "
                               + quote(service) + " Empty")
            } else {
                let args = servers.map(quote).joined(separator: " ")
                _ = try? shell("/usr/sbin/networksetup -setdnsservers "
                               + quote(service) + " " + args)
            }
        }
        flushCache()
    }

    private static func currentServers(_ service: String) -> [String] {
        guard let out = try? shell("/usr/sbin/networksetup -getdnsservers "
                                   + quote(service)) else { return [] }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().contains("aren't any") || trimmed.isEmpty { return [] }
        return trimmed.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func flushCache() {
        _ = try? shell("/usr/bin/dscacheutil -flushcache")
        _ = try? shell("/usr/bin/killall -HUP mDNSResponder")
    }

    private static func quote(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

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
