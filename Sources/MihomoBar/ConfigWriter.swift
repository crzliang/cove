import Foundation

/// 应用设置，持久化在 `Paths.settings`。
struct Settings: Codable, Equatable {
    /// Clash 订阅链接。填了就由内核自己用 `proxy-providers` 定时拉取并健康检查。
    var subscriptionURL: String = ""
    /// 本地 HTTP/SOCKS 混合端口
    var mixedPort: Int = 7890
    /// DNS 用的 fake-ip 还是 redir-host
    var tunEnabled: Bool = false
    /// rule / global / direct
    var mode: String = "rule"
    var logLevel: String = "info"
    /// 高级：直接使用一个已有的完整 Clash 配置（只读，绝不修改）
    var customConfigPath: String = ""

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settings),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return s
    }

    func save() throws {
        try Paths.ensureDirs()
        let data = try JSONEncoder().encode(self)
        try data.write(to: Paths.settings, options: .atomic)
    }
}

/// 生成内核配置。
///
/// 关键约束：**永远不写入、不修改用户自己的配置文件**。
/// 用户若指定了 `customConfigPath`，那份文件以只读方式经 `-f` 传给内核；
/// 否则这里生成一份应用自有的 `generated.yaml`。
enum ConfigWriter {

    /// 返回应当传给内核 `-f` 的配置文件路径。
    static func resolvedConfig(for settings: Settings) throws -> URL {
        let custom = settings.customConfigPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConfigError.customConfigMissing(url.path)
            }
            return url
        }
        try writeGenerated(settings)
        return Paths.generatedConfig
    }

    private static func writeGenerated(_ s: Settings) throws {
        try Paths.ensureDirs()
        let port = s.mixedPort

        var yaml = """
        # 由 MihomoBar 生成，请勿手工编辑。
        # 想用你自己的配置：在设置里指定「自定义配置路径」，本文件会被忽略。

        mixed-port: \(port)
        allow-lan: false
        bind-address: 127.0.0.1
        mode: \(s.mode)
        log-level: \(s.logLevel)
        ipv6: true
        unified-delay: true
        tcp-concurrent: true
        find-process-mode: "off"

        profile:
          store-selected: true
          store-fake-ip: true

        dns:
          enable: true
          ipv6: false
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          nameserver:
            - https://223.5.5.5/dns-query
            - https://1.1.1.1/dns-query
          fallback:
            - https://8.8.8.8/dns-query

        """

        if s.tunEnabled {
            yaml += """

            tun:
              enable: true
              stack: system
              auto-route: true
              auto-detect-interface: true
              dns-hijack:
                - any:53

            """
        }

        let sub = s.subscriptionURL.trimmingCharacters(in: .whitespaces)
        if sub.isEmpty {
            yaml += """

            proxy-groups:
              - name: PROXY
                type: select
                proxies:
                  - DIRECT

            rules:
              - MATCH,PROXY

            """
        } else {
            // 用 type: http 让内核自己按 interval 刷新并做健康检查，
            // 应用侧不需要任何定时任务。
            yaml += """

            proxy-providers:
              sub:
                type: http
                url: "\(escape(sub))"
                path: ./providers/sub.yaml
                interval: 3600
                health-check:
                  enable: true
                  interval: 300
                  url: https://www.gstatic.com/generate_204

            proxy-groups:
              - name: 🚀 节点选择
                type: select
                proxies:
                  - ♻️ 自动选择
                  - DIRECT
                use:
                  - sub
              - name: ♻️ 自动选择
                type: url-test
                tolerance: 50
                url: https://www.gstatic.com/generate_204
                interval: 300
                use:
                  - sub

            rules:
              - GEOIP,LAN,DIRECT,no-resolve
              - GEOIP,CN,DIRECT
              - MATCH,🚀 节点选择

            """
        }

        try yaml.write(to: Paths.generatedConfig, atomically: true, encoding: .utf8)
    }

    /// YAML 双引号字符串里只有 `\` 和 `"` 需要转义
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case customConfigMissing(String)

    var description: String {
        switch self {
        case .customConfigMissing(let p): return "自定义配置不存在：\(p)"
        }
    }
}
