import Foundation
import Darwin
import HelperProtocol

// 以 root 常驻的特权助手。
//
// 由 launchd 拉起（/Library/LaunchDaemons/local.cove.helper.plist），
// 通过 unix socket 接受 GUI 的请求。只在安装时授权一次，之后不再弹任何框 ——
// 这正是相比 osascript `with administrator privileges` 的核心优势：
// 后者每次调用都会弹授权框。
//
// 因为本身就是 root，这里可以直接 spawn mihomo 并持有 Process 句柄，
// 不需要 osascript、不需要 pid 回显、也不需要那套「花括号重定向」的绕法。

// MARK: - 日志

let logPath = "/var/log/local.cove.helper.log"

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] pid=\(getpid()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
        try? h.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
        // root 创建的文件给管理员组可读，方便排查
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: logPath)
    }
}

// MARK: - 内核管理

/// 助手的唯一状态。所有访问都串行化在 `queue` 上。
final class KernelSupervisor {
    private var process: Process?
    private let pidFile = "\(Helper.socketDirectory)/kernel.pid"

    init() {
        // 助手自身重启后（例如升级）内核可能还在跑，从 pid 文件恢复状态
        if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           Self.alive(pid) {
            log("恢复上次的内核 pid=\(pid)")
            lastKnownPID = pid
        } else {
            try? FileManager.default.removeItem(atPath: pidFile)
        }
    }

    private var lastKnownPID: pid_t?

    static func alive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    var currentPID: pid_t? {
        if let p = process, p.isRunning { return p.processIdentifier }
        if let pid = lastKnownPID, Self.alive(pid) { return pid }
        return nil
    }

    func start(config: String, dataDir: String, uiDir: String?,
               log logFile: String, port: Int, secret: String) throws -> pid_t {
        if let existing = currentPID {
            log("已有内核在跑 pid=\(existing)，先停掉")
            try stop()
        }

        var args = [
            "-d", dataDir,
            "-f", config,
            "-ext-ctl", "127.0.0.1:\(port)",
            "-ext-ctl-unix", "\(Helper.socketDirectory)/ctl.sock",
            "-secret", secret,
        ]
        if let uiDir, FileManager.default.fileExists(atPath: uiDir) {
            args += ["-ext-ui", uiDir]
        }

        let binary = "\(Helper.socketDirectory)/mihomo"
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw HelperFailure("内核二进制不可执行：\(binary)")
        }

        if !FileManager.default.fileExists(atPath: logFile) {
            FileManager.default.createFile(atPath: logFile, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile)) else {
            throw HelperFailure("无法打开日志文件：\(logFile)")
        }
        _ = try? handle.seekToEnd()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dataDir)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        try p.run()

        process = p
        lastKnownPID = p.processIdentifier
        _ = try? "\(p.processIdentifier)".write(toFile: pidFile, atomically: true, encoding: .utf8)
        log("内核已以 root 启动 pid=\(p.processIdentifier) port=\(port) config=\(config)")
        // macOS mDNSResponder 的 scoped DNS 会绕过 TUN hijack，拿到污染 IP；
        // 把系统 DNS 指到 fake-ip 网关，浏览器 / getaddrinfo 才会走 mihomo。
        DNSSetter.applyTunDNS()
        return p.processIdentifier
    }

    func stop() throws {
        guard let pid = currentPID else {
            try? FileManager.default.removeItem(atPath: pidFile)
            DNSSetter.restore()
            return
        }
        log("停止内核 pid=\(pid)（SIGTERM）")
        kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(5)
        while Self.alive(pid) && Date() < deadline {
            usleep(80_000)
        }
        if Self.alive(pid) {
            log("SIGTERM 超时，改用 SIGKILL pid=\(pid)")
            kill(pid, SIGKILL)
        }
        process = nil
        lastKnownPID = nil
        try? FileManager.default.removeItem(atPath: pidFile)
        try? FileManager.default.removeItem(atPath: "\(Helper.socketDirectory)/ctl.sock")
        DNSSetter.restore()
    }
}

struct HelperFailure: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

// MARK: - TUN DNS（修复 macOS scoped DNS 绕过劫持）

enum DNSSetter {
    private static let backupPath = "\(Helper.socketDirectory)/dns.backup.json"
    /// fake-ip / TUN 本机地址。系统解析器直接问这里，不依赖 dns-hijack。
    private static let tunDNS = "198.18.0.1"

    /// 备份并切换到 TUN DNS；已有备份则不重复覆盖。
    static func applyTunDNS() {
        let services = ProxySetter.activeServices()
        guard !services.isEmpty else { return }

        if !FileManager.default.fileExists(atPath: backupPath) {
            var backup: [String: [String]] = [:]
            for service in services {
                backup[service] = currentServers(service)
            }
            if let data = try? JSONSerialization.data(withJSONObject: backup) {
                try? data.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
            }
        }

        for service in services {
            _ = ProxySetter.run("/usr/sbin/networksetup",
                                ["-setdnsservers", service, tunDNS])
        }
        flushCache()
        log("已将系统 DNS 设为 \(tunDNS)（\(services.count) 个服务）")
    }

    /// 停内核时恢复；无备份则不动。
    static func restore() {
        guard FileManager.default.fileExists(atPath: backupPath) else { return }

        let services = ProxySetter.activeServices()
        var backup: [String: [String]] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: backupPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            backup = obj
        }
        try? FileManager.default.removeItem(atPath: backupPath)

        guard !services.isEmpty else { return }
        for service in services {
            let servers = backup[service] ?? []
            if servers.isEmpty {
                _ = ProxySetter.run("/usr/sbin/networksetup",
                                    ["-setdnsservers", service, "Empty"])
            } else {
                _ = ProxySetter.run("/usr/sbin/networksetup",
                                    ["-setdnsservers", service] + servers)
            }
        }
        flushCache()
        log("已恢复系统 DNS")
    }

    private static func currentServers(_ service: String) -> [String] {
        guard let out = ProxySetter.run("/usr/sbin/networksetup",
                                        ["-getdnsservers", service]) else { return [] }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「There aren't any DNS Servers…」表示走 DHCP
        if trimmed.lowercased().contains("aren't any") || trimmed.isEmpty { return [] }
        return trimmed.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func flushCache() {
        _ = ProxySetter.run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = ProxySetter.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }
}

// MARK: - 系统代理

enum ProxySetter {

    static func activeServices() -> [String] {
        guard let out = run("/usr/sbin/networksetup", ["-listallnetworkservices"]) else { return [] }
        return out.split(separator: "\n")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    static func set(enabled: Bool, port: Int) throws {
        let services = activeServices()
        guard !services.isEmpty else { throw HelperFailure("没有找到启用的网络服务") }

        let bypass = ["127.0.0.1", "localhost", "::1", "10.0.0.0/8",
                      "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "*.local"]

        for service in services {
            if enabled {
                try runOrThrow("/usr/sbin/networksetup", ["-setwebproxy", service, "127.0.0.1", "\(port)"])
                try runOrThrow("/usr/sbin/networksetup", ["-setsecurewebproxy", service, "127.0.0.1", "\(port)"])
                try runOrThrow("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, "127.0.0.1", "\(port)"])
                _ = run("/usr/sbin/networksetup", ["-setproxybypassdomains", service] + bypass)
            } else {
                try runOrThrow("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
                try runOrThrow("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
                try runOrThrow("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
            }
        }
        log("系统代理 \(enabled ? "开启 → 127.0.0.1:\(port)" : "关闭")，涉及 \(services.count) 个服务")
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func runOrThrow(_ path: String, _ args: [String]) throws {
        guard let out = run(path, args) else {
            throw HelperFailure("无法执行 \(path)")
        }
        // networksetup 失败时把错误写在 stdout
        if out.contains("Error") || out.contains("error") {
            throw HelperFailure("networksetup 失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

// MARK: - Socket 服务（收发原语在 HelperProtocol.HelperSocket 里，两边共用）

// MARK: - 请求处理

let supervisor = KernelSupervisor()
let queue = DispatchQueue(label: "helper.serial")

func handle(_ request: Helper.Request) -> Helper.Response {
    guard let command = request.command else {
        return .failure("未知命令：\(request.cmd)")
    }

    // 版本协商：协议不一致时让 GUI 提示重装助手，而不是用错字段默默失败
    if let v = request.protocolVersion, v != Helper.protocolVersion {
        return .failure("协议版本不匹配：请求 \(v)，助手 \(Helper.protocolVersion)")
    }

    do {
        switch command {
        case .ping:
            return Helper.Response(ok: true,
                                   pid: supervisor.currentPID.map(Int.init),
                                   running: supervisor.currentPID != nil,
                                   helperProtocolVersion: Helper.protocolVersion,
                                   detail: "uid=\(getuid()) pid=\(getpid())")

        case .startKernel:
            guard let config = request.config,
                  let dataDir = request.dataDir,
                  let logFile = request.logPath,
                  let port = request.port,
                  let secret = request.secret else {
                return .failure("startKernel 缺少必要参数")
            }
            let pid = try supervisor.start(config: config,
                                           dataDir: dataDir,
                                           uiDir: request.uiDir,
                                           log: logFile,
                                           port: port,
                                           secret: secret)
            return Helper.Response(ok: true, pid: Int(pid), running: true)

        case .stopKernel:
            try supervisor.stop()
            return Helper.Response(ok: true, running: false)

        case .kernelStatus:
            let pid = supervisor.currentPID
            return Helper.Response(ok: true, pid: pid.map(Int.init), running: pid != nil)

        case .setSystemProxy:
            guard let enabled = request.enabled else {
                return .failure("setSystemProxy 缺少 enabled")
            }
            try ProxySetter.set(enabled: enabled, port: request.port ?? 7890)
            return Helper.Response(ok: true, detail: enabled ? "系统代理已开启" : "系统代理已关闭")

        case .stageKernel:
            guard let source = request.kernelSource else {
                return .failure("stageKernel 缺少 kernelSource")
            }
            let dest = try stageKernelBinary(from: source)
            return Helper.Response(ok: true, detail: dest)

        case .uninstall:
            log("收到卸载请求")
            try supervisor.stop()
            uninstall()
            return Helper.Response(ok: true, detail: "助手已卸载")
        }
    } catch {
        let message = String(describing: error)
        log("命令 \(command.rawValue) 失败：\(message)")
        return .failure(message)
    }
}

/// 移除 launchd 配置与自身二进制，然后退出。
/// 先卸配置再删文件，否则 launchd 会因为找不到程序而反复重试。
func uninstall() {
    try? FileManager.default.removeItem(atPath: Helper.plistPath)
    let target = Helper.installedPath
    // 进程正在运行的二进制可以直接 unlink，内核会保留 inode 直到进程退出
    try? FileManager.default.removeItem(atPath: target)
    log("助手已卸载，退出")
    exit(0)
}

/// 把用户侧的 mihomo 拷进助手目录，供 root 执行。
///
/// 只接受 Application Support / app bundle 里的路径，避免随便指定系统文件被 root 化。
func stageKernelBinary(from source: String) throws -> String {
    let srcURL = URL(fileURLWithPath: source).resolvingSymlinksInPath()
    let src = srcURL.path
    guard isAllowedKernelSource(src) else {
        throw HelperFailure("拒绝的内核路径：\(src)")
    }
    guard FileManager.default.isExecutableFile(atPath: src) else {
        throw HelperFailure("内核不可执行：\(src)")
    }

    let dir = Helper.socketDirectory
    try FileManager.default.createDirectory(atPath: dir,
                                            withIntermediateDirectories: true)
    let dest = "\(dir)/mihomo"
    // 先写临时文件再替换，避免拷到一半被拿去执行
    let tmp = "\(dir)/mihomo.staging.\(getpid())"
    try? FileManager.default.removeItem(atPath: tmp)
    try FileManager.default.copyItem(atPath: src, toPath: tmp)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: tmp)
    // 清隔离属性，否则 Gatekeeper 会把 root 启动的内核直接 SIGKILL
    removexattr(tmp, "com.apple.quarantine", 0)
    // install(1) 等价：归 root:wheel
    chown(tmp, 0, 0)
    try? FileManager.default.removeItem(atPath: dest)
    try FileManager.default.moveItem(atPath: tmp, toPath: dest)
    log("已更新内核副本 → \(dest)")
    return dest
}

func isAllowedKernelSource(_ path: String) -> Bool {
    if path.hasSuffix("/Library/Application Support/Cove/mihomo") { return true }
    // 旧版数据迁过来之前，仍可能指向 MihomoBar 目录
    if path.hasSuffix("/Library/Application Support/MihomoBar/mihomo") { return true }
    if path.contains(".app/Contents/Resources/mihomo") { return true }
    return false
}

func serveConnection(_ client: Int32) {
    defer { close(client) }

    // 只接受本机管理员组用户。socket 权限已经限制了一层，这里是第二道。
    var uid = uid_t(), gid = gid_t()
    if getpeereid(client, &uid, &gid) == 0, uid != 0 {
        // 非 root 客户端的 gid 必须在 admin 组（gid 80）里
        if gid != 80 && !inAdminGroup(uid) {
            log("拒绝来自 uid=\(uid) gid=\(gid) 的连接")
            HelperSocket.writeAll(client, (try? Helper.encode(Helper.Response.failure("权限不足"))) ?? Data())
            return
        }
    }

    guard let line = HelperSocket.readLine(client), !line.isEmpty else { return }
    let response: Helper.Response
    do {
        let request = try Helper.decode(Helper.Request.self, from: line)
        // 所有状态变更串行执行，避免并发 start/stop 打架
        response = queue.sync { handle(request) }
    } catch {
        response = .failure("无法解析请求：\(error)")
    }
    if let data = try? Helper.encode(response) {
        HelperSocket.writeAll(client, data)
    }
}

func inAdminGroup(_ uid: uid_t) -> Bool {
    guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return false }
    guard let gr = getgrnam("admin") else { return false }
    let members = gr.pointee.gr_mem
    var i = 0
    while let member = members?[i] {
        if String(cString: member) == String(cString: name) { return true }
        i += 1
    }
    return false
}

// MARK: - 启动

func main() {
    log("助手启动，协议版本 \(Helper.protocolVersion)")

    // 助手由 launchd 拉起，默认 gid 是 daemon 而不是用户所在的组。
    // 若不显式 chown，socket 会是 root:daemon 0660 ——
    // 普通用户并不在 daemon 组里，结果就是「助手在跑但连不上」。
    var adminGID: gid_t = 80
    if let gr = getgrnam("admin") { adminGID = gr.pointee.gr_gid }

    let dir = Helper.socketDirectory
    try? FileManager.default.createDirectory(atPath: dir,
                                             withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o755])
    chown(dir, 0, adminGID)
    chmod(dir, 0o755)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { log("socket() 失败"); exit(1) }

    // 上次异常退出可能留下 socket 文件
    unlink(Helper.socketPath)

    guard HelperSocket.withAddress(Helper.socketPath, { bind(fd, $0, $1) }) == 0 else {
        log("bind() 失败 errno=\(errno)")
        exit(1)
    }
    // root:admin 0660 → 只有 root 和管理员组用户能连。
    // `getpeereid` 里还有第二道校验。
    chown(Helper.socketPath, 0, adminGID)
    chmod(Helper.socketPath, 0o660)

    guard listen(fd, 16) == 0 else {
        log("listen() 失败 errno=\(errno)")
        exit(1)
    }

    log("监听 \(Helper.socketPath)（root:admin 0660，admin gid=\(adminGID)）")

    while true {
        let client = accept(fd, nil, nil)
        if client < 0 {
            if errno == EINTR { continue }
            log("accept() 失败 errno=\(errno)")
            usleep(200_000)
            continue
        }
        DispatchQueue.global().async { serveConnection(client) }
    }
}

main()
