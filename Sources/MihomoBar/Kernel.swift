import Foundation
import Darwin

/// mihomo 内核进程的生命周期管理。
///
/// 所有设计决策都基于对 mihomo v1.19 的实测：
/// * 日志走 **stdout**（不是 stderr），所以两者都要重定向到文件
/// * `-t` 可做启动前配置预检，返回 "test is successful"
/// * `-ext-ctl` / `-ext-ui` / `-secret` 都是命令行覆盖，不必改动配置yaml
/// * 内核被 kill 后 unix socket 文件会残留，下次启动前必须 unlink
/// * `Child.kill()` 等价 SIGKILL，会导致 TUN 模式残留路由 → 必须走 SIGTERM
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

    private var process: Process?
    private var logHandle: FileHandle?
    private var stderrPipe: Pipe?

    var endpoint: URL? {
        guard status.isRunning else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    // MARK: - 启动

    func start(config: URL, binary: URL, dataDir: URL, uiDir: URL?) async {
        guard !status.isRunning, !status.isBusy else { return }
        lastError = nil
        status = .starting

        do {
            try Paths.ensureDirs()

            // 1. 启动前预检：配置有问题会在这一步暴露，而不是等内核静默退出
            try Self.validate(config: config, binary: binary, dataDir: dataDir)

            // 2. 选一个真正空闲的端口，避免与 ClashX / Clash Verge 抢 9090
            guard let freePort = Self.findFreePort() else {
                throw KernelError.noFreePort
            }
            port = freePort
            secret = Self.randomSecret()

            // 3. 清理可能残留的 socket，否则内核会拒绝启动
            Self.removeStaleSocket(at: Paths.controlSocket)

            // 4. 组装参数。注意：全部是命令行覆盖，用户 config.yaml 只读传入。
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

            let handle = try openLogHandle()
            logHandle = handle
            Self.appendLog("=== start pid=? port=\(freePort) config=\(config.path) ===")

            let p = Process()
            p.executableURL = binary
            p.arguments = args
            p.currentDirectoryURL = dataDir
            p.standardInput = FileHandle.nullDevice
            // 实测 mihomo 日志走 stdout。早先只重定向 stderr 的实现会得到空日志。
            p.standardOutput = handle
            p.standardError = handle

            // 内核先于 GUI 死亡时必须能感知，避免 UI 显示"运行中"但实际已挂
            p.terminationHandler = { [weak self] proc in
                Task { @MainActor in
                    self?.handleTermination(proc)
                }
            }

            try p.run()
            process = p

            // 5. 等 RESTful API 真的起来，而不是 sleep 固定秒数
            let ready = await Self.waitUntilReady(port: freePort, secret: secret, timeout: 15)
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
    /// 直接用 `Process.terminate()` 就是 SIGTERM；不要用 `kill(pid, SIGKILL)`，
    /// 那会让 TUN 模式残留 utun 接口和路由。
    func stop() {
        guard let p = process, p.isRunning else {
            cleanup()
            status = .stopped
            return
        }
        status = .stopping
        p.terminate()   // SIGTERM

        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            usleep(80_000)
        }
        if p.isRunning {
            Self.appendLog("!!! SIGTERM 超时，改用 SIGKILL")
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
        }
        Self.appendLog("=== stopped ===")
        cleanup()
        status = .stopped
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
        try? logHandle?.close()
        logHandle = nil
        stderrPipe = nil
        // 实测：内核退出后 unix socket 文件仍留在磁盘上。
        // 启动前会再清一次，但这里也清，避免残留文件误导外部工具。
        Self.removeStaleSocket(at: Paths.controlSocket)
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

    /// 日志超过 4 MB 就轮转一次，避免无限增长。
    private func openLogHandle() throws -> FileHandle {
        let url = Paths.kernelLog
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 4 * 1024 * 1024 {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        return h
    }

    private func writeRuntimeInfo() {
        guard status.isRunning else { return }
        let info: [String: Any] = [
            "port": port,
            "secret": secret,
            "controller": "http://127.0.0.1:\(port)",
            "unixSocket": Paths.controlSocket.path,
            "ui": "http://127.0.0.1:\(port)/ui/",
            "pid": process?.processIdentifier ?? 0,
        ]
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
                .map(String.init) ?? out.suffix(300).description
            throw KernelError.configInvalid(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 让内核自己挑：向 127.0.0.1:0 绑定拿一个系统分配的空闲端口。
    /// 存在 TOCTOU 竞态，但比硬编码 9090 强得多。
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
        // 实测：内核被 kill 后 srw-rw-rw- 的 socket 文件仍然躺在磁盘上，
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
