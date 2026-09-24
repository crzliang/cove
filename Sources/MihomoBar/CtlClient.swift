import Foundation

/// mihomo RESTful API 客户端。
///
/// 这里只做「托盘里需要立刻看到/操作」的少数几个接口 ——
/// 完整的仪表盘（节点列表、规则、连接、流量曲线）由内核自带的
/// MetaCubeXD 在浏览器里提供，不必重复实现。
struct CtlClient {

    let base: URL
    let secret: String

    init(base: URL, secret: String) {
        self.base = base
        self.secret = secret
    }

    // MARK: - 数据模型

    struct VersionInfo: Decodable {
        let version: String
        let meta: Bool?
    }

    struct ConfigsInfo: Decodable {
        let mode: String?
        let port: Int?
        let mixedPort: Int?
        let `interface`: String?

        enum CodingKeys: String, CodingKey {
            case mode, port, `interface`
            case mixedPort = "mixed-port"
        }
    }

    struct ProxyEntry: Decodable {
        let type: String
        let now: String?
        let all: [String]?
        let history: [DelayRecord]?

        var isGroup: Bool { all != nil }

        /// 取最近一次延迟测试结果（毫秒），无记录返回 nil。
        var latestDelay: Int? { history?.last?.delay }

        struct DelayRecord: Decodable {
            let time: String?
            let delay: Int
        }
    }

    struct ProxiesResponse: Decodable {
        let proxies: [String: ProxyEntry]
    }

    struct DelayResponse: Decodable {
        let delay: Int
        let message: String?
    }

    struct ProviderEntry: Decodable {
        let name: String?
        let vehicleType: String?
        let updatedAt: String?
        let proxies: [ProxyEntry]?

        var nodeCount: Int { proxies?.count ?? 0 }
    }

    struct ProvidersResponse: Decodable {
        let providers: [String: ProviderEntry]
    }

    // MARK: - 请求

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: base) else {
            throw CtlError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 6
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func fetch<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: request(path, method: method, body: body))
        guard let http = resp as? HTTPURLResponse else { throw CtlError.noResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CtlError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func perform(_ path: String, method: String, body: [String: Any]? = nil) async throws {
        let (data, resp) = try await URLSession.shared.data(for: request(path, method: method, body: body))
        guard let http = resp as? HTTPURLResponse else { throw CtlError.noResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CtlError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - 接口

    func version() async throws -> VersionInfo {
        try await fetch("/version")
    }

    func configs() async throws -> ConfigsInfo {
        try await fetch("/configs")
    }

    func proxies() async throws -> [String: ProxyEntry] {
        let response: ProxiesResponse = try await fetch("/proxies")
        return response.proxies
    }

    /// 切换 rule / global / direct
    func setMode(_ mode: String) async throws {
        try await perform("/configs", method: "PATCH", body: ["mode": mode])
    }

    func select(group: String, node: String) async throws {
        let g = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        try await perform("/proxies/\(g)", method: "PUT", body: ["name": node])
    }

    func delay(node: String, timeoutMS: Int = 3000,
               testURL: String = "http://www.gstatic.com/generate_204") async throws -> Int {
        let n = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        var comps = URLComponents()
        comps.path = "/proxies/\(n)/delay"
        comps.queryItems = [
            URLQueryItem(name: "timeout", value: String(timeoutMS)),
            URLQueryItem(name: "url", value: testURL),
        ]
        let result: DelayResponse = try await fetch(comps.string ?? "")
        return result.delay
    }

    /// 策略组订阅（proxy-providers）当前状态：节点数、最近更新时间
    func providers() async throws -> [String: ProviderEntry] {
        let response: ProvidersResponse = try await fetch("/providers/proxies")
        return response.providers
    }

    /// 命令内核立即重新拉取订阅。
    /// 平时不需要调 —— `proxy-providers` 配了 `interval` 后内核会自己刷新。
    func updateProvider(_ name: String) async throws {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        try await perform("/providers/proxies/\(n)", method: "PUT")
    }

    /// 让内核重新读取磁盘上的配置（订阅更新后调用）
    func reloadConfig() async throws {
        try await perform("/configs?force=true", method: "PUT", body: ["path": "", "payload": ""])
    }
}

enum CtlError: Error, CustomStringConvertible {
    case badURL(String)
    case noResponse
    case http(Int, String)

    var description: String {
        switch self {
        case .badURL(let p):        return "非法地址: \(p)"
        case .noResponse:           return "控制器无响应"
        case .http(let code, let b): return "控制器返回 \(code)\(b.isEmpty ? "" : ": \(b.prefix(200))")"
        }
    }
}
