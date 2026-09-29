import Foundation

/// 用系统网络拉取订阅并落盘，避免走内核 DNS/代理（尚未有节点时会解析失败）。
enum SubscriptionFetcher {

    enum FetchError: Error, CustomStringConvertible {
        case badURL(String)
        case http(Int)
        case empty
        case notClashYAML

        var description: String {
            switch self {
            case .badURL(let s):   return "订阅链接无效：\(s)"
            case .http(let code):  return "订阅服务器返回 \(code)"
            case .empty:           return "订阅内容为空"
            case .notClashYAML:    return "订阅不是 Clash/Mihomo YAML（需要含 proxies:）。若是通用订阅链接，试试在末尾加 &client=clash"
            }
        }
    }

    struct Result {
        var nodeCount: Int
        var upload: Int?
        var download: Int?
        var total: Int?
    }

    /// 下载并写入对应订阅文件。节点数按 `- name:` 行粗算；用量来自 `subscription-userinfo`。
    @discardableResult
    static func downloadAndStore(_ entry: SubscriptionEntry) async throws -> Result {
        let trimmed = entry.trimmedURL
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            throw FetchError.badURL(trimmed)
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("clash.meta", forHTTPHeaderField: "User-Agent")

        // 绕过系统代理：订阅要在「还没节点」时也能拉下来
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw FetchError.empty }

        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let yaml = try normalizeToClashYAML(text)
        let count = yaml.split(separator: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- name:")
        }.count

        try Paths.ensureDirs()
        try yaml.write(to: Paths.subscriptionFile(id: entry.id), atomically: true, encoding: .utf8)

        let info = (response as? HTTPURLResponse).flatMap {
            parseUserInfo($0.value(forHTTPHeaderField: "subscription-userinfo"))
        }
        return Result(nodeCount: count,
                      upload: info?.upload,
                      download: info?.download,
                      total: info?.total)
    }

    private struct UserInfo {
        var upload: Int
        var download: Int
        var total: Int
    }

    /// `upload=1; download=2; total=3; expire=…`
    private static func parseUserInfo(_ raw: String?) -> UserInfo? {
        guard let raw, !raw.isEmpty else { return nil }
        var map: [String: Int] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            guard let number = Int(value) else { continue }
            map[key] = number
        }
        guard map["upload"] != nil || map["download"] != nil || map["total"] != nil else { return nil }
        return UserInfo(upload: map["upload"] ?? 0,
                        download: map["download"] ?? 0,
                        total: map["total"] ?? 0)
    }

    /// 接受原生 YAML，或把 base64 的分享链接列表拒绝掉并给出提示。
    private static func normalizeToClashYAML(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeClashYAML(trimmed) { return trimmed }

        // 有的源默认返回 base64(分享链接)；解出来也不是 YAML
        if let decoded = Data(base64Encoded: trimmed),
           let asText = String(data: decoded, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           looksLikeClashYAML(asText) {
            return asText
        }

        throw FetchError.notClashYAML
    }

    private static func looksLikeClashYAML(_ text: String) -> Bool {
        // 完整配置或仅 proxies 列表
        text.contains("proxies:") || text.contains("proxy-groups:")
    }
}
