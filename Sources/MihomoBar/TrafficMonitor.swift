import Foundation
import HelperProtocol

/// 实时流量监控。
///
/// mihomo 的 `/traffic` 是一个**长连接流式接口**，每秒推一行 JSON：
/// `{"up":1234,"down":5678}`（单位 字节/秒）。
/// 不能用普通的 `data(for:)` —— 那会一直等到连接关闭才返回。
/// 这里用 `URLSession.bytes` 逐行读。
@MainActor
final class TrafficMonitor: ObservableObject {

    struct Point: Identifiable, Equatable {
        let id: Date
        let at: Date
        let up: Int
        let down: Int
    }

    @Published private(set) var up: Int = 0
    @Published private(set) var down: Int = 0
    @Published private(set) var active: Bool = false
    /// 近约 2 分钟的速率采样，供概览曲线使用（不落盘）。
    @Published private(set) var history: [Point] = []

    private let historyLimit = 120
    private var task: Task<Void, Never>?
    /// 当前订阅的控制器地址；内核重启（换端口/密钥）后必须重连。
    private var currentBase: URL?
    private var currentSecret: String?

    private struct Sample: Decodable {
        let up: Int
        let down: Int
    }

    func start(base: URL, secret: String) {
        if task != nil, currentBase == base, currentSecret == secret {
            return
        }
        stop()
        currentBase = base
        currentSecret = secret
        task = Task { [weak self] in
            await self?.loop(base: base, secret: secret)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        currentBase = nil
        currentSecret = nil
        up = 0
        down = 0
        active = false
        history = []
    }

    private func loop(base: URL, secret: String) async {
        guard let url = URL(string: "/traffic", relativeTo: base) else { return }
        var request = URLRequest(url: url)
        // 流式接口会一直推数据；超时只约束建连/首包，别用太短的值。
        request.timeoutInterval = 30
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")

        // 断线重连：内核重启、端口变化都会走到这里
        while !Task.isCancelled {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                active = true
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard let data = line.data(using: .utf8),
                          let sample = try? JSONDecoder().decode(Sample.self, from: data) else { continue }
                    up = sample.up
                    down = sample.down
                    appendHistory(up: sample.up, down: sample.down)
                }
                active = false
            } catch {
                active = false
                if Task.isCancelled { return }
            }
            // 退避后再试，避免内核没起来时疯狂重连
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func appendHistory(up: Int, down: Int) {
        let now = Date()
        history.append(Point(id: now, at: now, up: up, down: down))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    // MARK: - 显示格式化

    static func rate(_ bytesPerSecond: Int) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(bytesPerSecond)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(Int(value)) \(units[index])"
            : String(format: "%.1f %@", value, units[index])
    }

    static func volume(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(Int(value)) \(units[index])"
            : String(format: "%.1f %@", value, units[index])
    }
}
