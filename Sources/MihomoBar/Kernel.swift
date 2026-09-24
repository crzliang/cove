import Foundation
import Darwin

/// mihomo 内核进程的生命周期管理。
///
/// 支持两种启动方式：
///
/// * **用户态**（`privileged: false`）—— 由 `Process` 直接 spawn，能拿到
///   terminationHandler，生命周期与 GUI 绑定。
/// * **提权态**（`privileged: true`）—— 经 `osascript ... with administrator
///   privileges` 以 root 启动，TUN 模式必需。进程被 launchd 接管，不随 GUI 退出，
///   因此存活检测只能靠轮询 pid。
///
/// 所有设计决策都基于对 mihomo v1.19 的实测：
/// * 日志走 **stdout**（不是 stderr），所以两者都要重定向到文件
/// * `-t` 可做启动前配置预检，返回 "test is successful"
/// * `-ext-ctl` / `-ext-ui` / `-secret` 都是命令行覆盖，不必改动配置 yaml
/// * 内核退出后 unix socket 文件会残留，下次启动前必须 unlink
/// * `kill(pid, SIGKILL)` 会让 TUN 模式残留 utun 接口和路由 → 必须走 SIGTERM
@MainActor
final class Kernel: ObservableObject {

    enum Status: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case stopping
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
        var isBusy: Bool {
            switch self {
            case .starting, .stopping: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .stopped:          return "已停止"
            case .starting:         return "启动中…"
            case .running(let p):   return "运行中 :\(p)"
            case .stopping:         return "停止中…"
            case .failed:           return "启动失败"
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastError: String?

    /// 当前实例的控制器端口与 secret；仅运行中有效。
    private(set) var port: Int = 0
    private(set) var secret: String = ""

    /// 内核是否以 root 运行（TUN 模式需要）
    private(set) var isPrivileged = false

    private var process: Process?        // 用户态句柄
    private var rootPID: pid_t?          // 提权态 pid
    private var logHandle: FileHandle?

    var endpoint: URL? {
        guard status.isRunning else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// 当前内核 pid（用户态或提权态）。退出时用来确认是否真的收干净了。
    var runningPID: pid_t? { rootPID ?? process?.processIdentifier }

    // MARK: - 启动

    func start(config: URL, binary: URL, dataDir: URL, uiDir: URL?, privileged: Bool) async {
        guard !status.isRunning, !status.isBusy else { return }
        lastError = nil
        status = .starting

        do {
            try Paths.ensureDirs()

            // 上次留下的提权内核不会随 GUI 退出，先收掉，否则端口和 TUN 会打架
            await adoptOrReapLeftover()

            // 1. 启动前预检：配置有问题会在这一步暴露，而不是等内核静默退出
            try Self.validate(config: config, binary: binary, dataDir: dataDir)

            // 2. 选一个真正空闲的端口，避免与 ClashX / Clash Verge 抢 9090
            guard let freePort = Self.findFreePort() else { throw KernelError.noFreePort }
            port = freePort
            secret = Self.randomSecret()

            // 3. 清理可能残留的 socket，否则内核会拒绝启动
            Self.removeStaleSocket(at: Paths.controlSocket)

            // 4. 组装参数。全部是命令行覆盖，用户 config.yaml 只读传入。
            var args = [
                "-d", dataDir.path,
                "-f", config.path,
                "-ext-ctl", "127.0.0.1:\(freePort)",
                "-ext-ctl-unix", Paths.controlSocket.path,
                "-secret", secret,
            ]
            if let uiDir, FileManager.default.fileExists(atPath: uiDir.path) {
                args += ["-ext-ui", uiDir.path]
            }

            Self.rotateLogIfNeeded()
            Self.appendLog("=== start privileged=\(privileged) port=\(freePort) config=\(config.path) ===")

            if privileged {
                let pid = try Privileged.spawnAsRoot(
                    executable: binary,
                    arguments: args,
                    logPath: Paths.kernelLog.path,
                    workingDirectory: dataDir.path
                )
                rootPID = pid
                isPrivileged = true
                Self.appendLog("=== privileged pid=\(pid) ===")
            } else {
                let handle = try openLogHandle()
                logHandle = handle

                let p = Process()
                p.executableURL = binary
                p.arguments = args
                p.currentDirectoryURL = dataDir
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = handle
                p.standardError = handle
                p.terminationHandler = { [weak self] proc in
                    Task { @MainActor in self?.handleTermination(proc) }
                }
                try p.run()
                process = p
                isPrivileged = false
            }

            // 5. 等 RESTful API 真的起来，而不是 sleep 固定秒数。
            //    提权模式要多给点时间（TUN 建接口、改路由比较慢）。
            let ready = await Self.waitUntilReady(port: freePort,
                                                  secret: secret,
                                                  timeout: privileged ? 25 : 15)
            guard ready else {
                let tail = tailLog(lines: 15)
                stop()
                throw KernelError.notReady(tail)
            }

            status = .running(port: freePort)
            writeRuntimeInfo()
        } catch {
            let message = (error as? KernelError)?.description ?? String(describing: error)
            lastError = message
            status = .failed(message)
            Self.appendLog("!!! \(message)")
            cleanup()
        }
    }

    // MARK: - 停止

    /// 优雅退出：SIGTERM → 最多等 3 秒 → SIGKILL 兜底。
    ///
    /// 不要用 SIGKILL 直接杀，那会让 TUN 模式残留 utun 接口和路由。
    func stop() {
        let pid = rootPID
        let proc = process

        guard pid != nil || (proc?.isRunning ?? false) else {
            cleanup()
            status = .stopped
            return
        }
        status = .stopping

        if let pid {
            // 提权进程：我们只有发送信号的权限，身份是 root 所以每次都要走 osascript
            try? Privileged.signal(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(3)
            while Privileged.processExists(pid) && Date() < deadline {
                usleep(80_000)
            }
            if Privileged.processExists(pid) {
                Self.appendLog("!!! SIGTERM 超时，改用 SIGKILL")
                try? Privileged.signal(pid, SIGKILL)
            }
        } else if let proc {
            proc.terminate()   // SIGTERM
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning && Date() < deadline {
                usleep(80_000)
            }
            if proc.isRunning {
                Self.appendLog("!!! SIGTERM 超时，改用 SIGKILL")
                kill(proc.processIdentifier, SIGKILL)
                proc.waitUntilExit()
            }
        }

        Self.appendLog("=== stopped ===")
        cleanup()
        status = .stopped
    }

    /// 轮询用：提权内核没有 terminationHandler，只能查 pid。
    /// 用户态的退出由 `terminationHandler` 处理，这里是兜底。
    func refreshLiveness() {
        guard status.isRunning else { return }
        if let pid = rootPID {
            if !Privileged.processExists(pid) {
                Self.appendLog("=== privileged kernel \(pid) 已消失 ===")
                cleanup()
                status = .stopped
            }
        } else if let p = process, !p.isRunning {
            cleanup()
            status = .stopped
        }
    }

    private func handleTermination(_ proc: Process) {
        guard process === proc else { return }
        let code = proc.terminationStatus
        Self.appendLog("=== kernel exited code=\(code) ===")
        if case .stopping = status { return }   // 是我们主动停的
        if code != 0 {
            lastError = "内核异常退出（code \(code)）"
            status = .failed(lastError!)
        } else {
            status = .stopped
        }
        cleanup()
    }

    private func cleanup() {
        process = nil
        rootPID = nil
        isPrivileged = false
        try? logHandle?.close()
        logHandle = nil
        Self.removeStaleSocket(at: Paths.controlSocket)
        try? FileManager.default.removeItem(at: Paths.runtimeInfo)
    }

    /// 处理上一次运行遗留的实例。
    ///
    /// 提权内核被 launchd 接管，GUI 退出后仍在跑 —— 重新启动 GUI 时必须先收掉它，
    /// 否则 TUN 接口和端口会冲突（表现为「启动了但没效果」）。
    private func adoptOrReapLeftover() async {
        guard let data = try? Data(contentsOf: Paths.runtimeInfo),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["pid"] as? Int, raw > 0 else { return }
        let pid = pid_t(raw)
        guard Privileged.processExists(pid) else {
            try? FileManager.default.removeItem(at: Paths.runtimeInfo)
            return
        }
        Self.appendLog("=== 收掉上次遗留的提权内核 pid=\(pid) ===")
        try? Privileged.signal(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while Privileged.processExists(pid) && Date() < deadline {
            usleep(80_000)
        }
        if Privileged.processExists(pid) {
            try? Privileged.signal(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: Paths.runtimeInfo)
    }

    // MARK: - 日志

    func tailLog(lines: Int) -> String { Self.tailLog(lines: lines) }

    static func tailLog(lines: Int) -> String {
        guard let text = try? String(contentsOf: Paths.kernelLog, encoding: .utf8) else {
            return "（还没有日志，先启动一次内核）"
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(max(1, lines)).joined(separator: "\n")
    }

    private static func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: Paths.kernelLog) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        }
    }

    private static func rotateLogIfNeeded() {
        let url = Paths.kernelLog
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 4 * 1024 * 1024 else { return }
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// 用户态启动时用的可写句柄。提权模式由 shell 负责重定向，用不到这个。
    private func openLogHandle() throws -> FileHandle {
        let url = Paths.kernelLog
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        return h
    }

    private func writeRuntimeInfo() {
        guard status.isRunning else { return }
        var info: [String: Any] = [
            "port": port,
            "secret": secret,
            "controller": "http://127.0.0.1:\(port)",
            "unixSocket": Paths.controlSocket.path,
            "ui": "http://127.0.0.1:\(port)/ui/",
            "privileged": isPrivileged,
        ]
        info["pid"] = rootPID.map { Int($0) } ?? process.map { Int($0.processIdentifier) } ?? 0
        if let data = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted) {
            try? data.write(to: Paths.runtimeInfo)
        }
    }

    // MARK: - 静态辅助

    /// `mihomo -t -f <config>`：配置有问题时立即失败，不留下半个内核进程。
    static func validate(config: URL, binary: URL, dataDir: URL) throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["-t", "-d", dataDir.path, "-f", config.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let out = String(data: data, encoding: .utf8) ?? ""
            let reason = out.split(separator: "\n")
                .last { $0.contains("msg=") || $0.contains("error") }
                .map(String.init) ?? String(out.suffix(300))
            throw KernelError.configInvalid(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 让系统分配一个空闲端口。存在 TOCTOU 竞态，但比硬编码 9090 强得多。
    static func findFreePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { return nil }

        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func removeStaleSocket(at url: URL) {
        // 实测：内核退出后 srw-rw-rw- 的 socket 文件仍然躺在磁盘上，
        // 不清理会导致下次启动失败。
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 轮询 /version 直到可用，而不是 sleep 一个猜出来的秒数。
    private static func waitUntilReady(port: Int, secret: String, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/version") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }
}

enum KernelError: Error, CustomStringConvertible {
    case noFreePort
    case configInvalid(String)
    case notReady(String)

    var description: String {
        switch self {
        case .noFreePort:
            return "找不到可用端口"
        case .configInvalid(let detail):
            return "配置预检失败：\(detail)"
        case .notReady(let log):
            return "内核未在超时内就绪。\n最近日志：\n\(log)"
        }
    }
}
