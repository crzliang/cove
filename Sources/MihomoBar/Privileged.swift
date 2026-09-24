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
        // AppleScript 字符串里需要转义的只有反斜杠和双引号
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
            if msg.contains("-128") {
                throw PrivilegedError.cancelled
            }
            throw PrivilegedError.failed(msg.isEmpty ? "退出码 \(p.terminationStatus)" : msg)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

enum PrivilegedError: Error, CustomStringConvertible {
    case cancelled
    case failed(String)

    var description: String {
        switch self {
        case .cancelled:        return "已取消授权"
        case .failed(let m):    return "提权执行失败：\(m.trimmingCharacters(in: .whitespacesAndNewlines))"
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
