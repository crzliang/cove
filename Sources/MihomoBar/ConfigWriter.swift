import Foundation

/// 一条订阅。
struct SubscriptionEntry: Codable, Equatable, Identifiable {
    /// 短 id，同时用作 provider 名后缀与落盘文件名（`sub-<id>` / `<id>.yaml`）
    var id: String
    var name: String
    var url: String
    var enabled: Bool
    /// 最近一次成功下载的节点粗算数量（内核未运行时也能显示）
    var lastNodeCount: Int?

    static func make(name: String, url: String) -> SubscriptionEntry {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return SubscriptionEntry(id: id, name: name, url: url, enabled: true, lastNodeCount: nil)
    }

    var providerName: String { "sub-\(id)" }

    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isUsable: Bool { enabled && !trimmedURL.isEmpty }
}

/// 用户自定义分流规则，写入 generated.yaml 的 rules 段（排在内置 GEOIP/MATCH 之前）。
struct CustomRule: Codable, Equatable, Identifiable {
    var id: String
    var type: String
    var payload: String
    var proxy: String
    var noResolve: Bool
    var enabled: Bool

    static let commonTypes: [String] = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD",
        "GEOSITE", "GEOIP", "IP-CIDR", "IP-CIDR6",
        "PROCESS-NAME", "PROCESS-PATH", "MATCH",
    ]

    static func make(type: String = "DOMAIN-SUFFIX",
                     payload: String = "",
                     proxy: String = "DIRECT",
                     noResolve: Bool = false) -> CustomRule {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return CustomRule(id: id, type: type, payload: payload,
                          proxy: proxy, noResolve: noResolve, enabled: true)
    }

    /// Clash/Mihomo 规则行，例如 `DOMAIN-SUFFIX,google.com,DIRECT`
    var clashLine: String? {
        let t = type.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let p = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !p.isEmpty else { return nil }
        if t == "MATCH" {
            return "MATCH,\(p)"
        }
        let body = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        var line = "\(t),\(body),\(p)"
        if noResolve {
            line += ",no-resolve"
        }
        return line
    }
}

/// 应用设置，持久化在 `Paths.settings`。
struct Settings: Codable, Equatable {
    /// 订阅列表（可多条）。旧版单字段 `subscriptionURL` 会在解码时迁进来。
    var subscriptions: [SubscriptionEntry] = []
    /// 用户自定义规则（生成配置时插入内置规则之前）。
    var customRules: [CustomRule] = []
    /// 本地 HTTP/SOCKS 混合端口
    var mixedPort: Int = 7890
    /// DNS 用的 fake-ip 还是 redir-host
    var tunEnabled: Bool = false
    /// rule / global / direct
    var mode: String = "rule"
    var logLevel: String = "info"
    /// 高级：直接使用一个已有的完整 Clash 配置（只读，绝不修改）
    var customConfigPath: String = ""
    /// 是否在 Dock 中显示图标。关掉就退化成纯菜单栏应用。
    var showInDock: Bool = true
    /// 启动时是否自动打开主窗口。
    ///
    /// 不用启发式判断「是不是开机自启拉起的」—— 试过两条路都不行：
    /// `NSAppleEventManager.currentAppleEvent`（open 启动时为 nil）和
    /// `NSApplicationLaunchIsDefaultLaunchKey`（终端启动时也是 false，实测确认）。
    /// 与其瞎猜，不如给用户一个开关；开启「开机自启」时会自动关掉它。
    var showWindowOnLaunch: Bool = true
    /// 启动应用时是否自动启动内核。
    var startKernelOnLaunch: Bool = true

    /// 窗口位置是否由**用户拖动**决定过。
    ///
    /// 不用这个标记的话会有个鸡生蛋问题：应用自己把窗口放到某个位置 → 自动保存 →
    /// 下次启动“恢复”到那个位置。实测就是窗口反复出现在第二块屏幕上（用户从没放过）。
    /// 只有用户真正拖过窗口，才尊重保存的坐标。
    var windowPositionIsUserChosen: Bool = false

    /// 当前启用且链接非空的订阅
    var activeSubscriptions: [SubscriptionEntry] {
        subscriptions.filter(\.isUsable)
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settings) else { return Settings() }
        do {
            var decoded = try JSONDecoder().decode(Settings.self, from: data)
            // 旧版 subscriptionURL 已迁入列表：立刻落盘成新格式，并搬迁旧缓存文件
            if let raw = String(data: data, encoding: .utf8),
               raw.contains("\"subscriptionURL\""),
               decoded.subscriptions.contains(where: { $0.id == "legacy" }) {
                let oldFile = Paths.dataDir.appendingPathComponent("providers/sub.yaml")
                let newFile = Paths.subscriptionFile(id: "legacy")
                if FileManager.default.fileExists(atPath: oldFile.path),
                   !FileManager.default.fileExists(atPath: newFile.path) {
                    try? FileManager.default.moveItem(at: oldFile, to: newFile)
                }
                try? decoded.save()
            }
            return decoded
        } catch {
            // 解码失败不能默默吞掉 —— 用户会看到设置“自己变回去了”却不知为何。
            // 备份一份脏数据，方便排查。
            let backup = Paths.settings.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? data.write(to: backup)
            NSLog("[MihomoBar] settings.json 解析失败，已备份到 \(backup.path)：\(error)")
            return Settings()
        }
    }

    func save() throws {
        try Paths.ensureDirs()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.settings, options: .atomic)
    }
}

// MARK: - 向后兼容的解码

extension Settings {

    private enum CodingKeys: String, CodingKey {
        case subscriptions, subscriptionURL, customRules, mixedPort, tunEnabled, mode, logLevel
        case customConfigPath, showInDock, windowPositionIsUserChosen
        case showWindowOnLaunch, startKernelOnLaunch
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(subscriptions, forKey: .subscriptions)
        try c.encode(customRules, forKey: .customRules)
        try c.encode(mixedPort, forKey: .mixedPort)
        try c.encode(tunEnabled, forKey: .tunEnabled)
        try c.encode(mode, forKey: .mode)
        try c.encode(logLevel, forKey: .logLevel)
        try c.encode(customConfigPath, forKey: .customConfigPath)
        try c.encode(showInDock, forKey: .showInDock)
        try c.encode(windowPositionIsUserChosen, forKey: .windowPositionIsUserChosen)
        try c.encode(showWindowOnLaunch, forKey: .showWindowOnLaunch)
        try c.encode(startKernelOnLaunch, forKey: .startKernelOnLaunch)
        // 不再写出 subscriptionURL；解码端仍可读旧字段做迁移
    }

    /// 手写解码，而不是用编译器合成的。
    ///
    /// Swift 合成的 `init(from:)` 对**缺失的非可选字段会直接抛 `keyNotFound`**，
    /// 哪怕属性声明里写了默认值 —— 已实测确认。后果是：给 Settings 新增一个字段，
    /// 就会让所有老用户的 `settings.json` 解码失败，全部设置静默回退成默认值。
    ///
    /// 改用 `decodeIfPresent` + 默认值，之后新增字段就永远安全。
    ///
    /// 注意：这个 extension 必须写在 struct 体**外面**。一旦把 `init(from:)`
    /// 写进 struct 体内，编译器就不再合成 `init()`，所有 `Settings()` 调用都会编译失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()   // 默认值来源
        mixedPort        = try c.decodeIfPresent(Int.self,    forKey: .mixedPort)        ?? d.mixedPort
        tunEnabled       = try c.decodeIfPresent(Bool.self,   forKey: .tunEnabled)       ?? d.tunEnabled
        mode             = try c.decodeIfPresent(String.self, forKey: .mode)             ?? d.mode
        logLevel         = try c.decodeIfPresent(String.self, forKey: .logLevel)         ?? d.logLevel
        customConfigPath = try c.decodeIfPresent(String.self, forKey: .customConfigPath) ?? d.customConfigPath
        showInDock       = try c.decodeIfPresent(Bool.self,   forKey: .showInDock)       ?? d.showInDock
        windowPositionIsUserChosen
                         = try c.decodeIfPresent(Bool.self,   forKey: .windowPositionIsUserChosen)
                           ?? d.windowPositionIsUserChosen
        showWindowOnLaunch
                         = try c.decodeIfPresent(Bool.self,   forKey: .showWindowOnLaunch)
                           ?? d.showWindowOnLaunch
        startKernelOnLaunch
                         = try c.decodeIfPresent(Bool.self,   forKey: .startKernelOnLaunch)
                           ?? d.startKernelOnLaunch
        customRules      = try c.decodeIfPresent([CustomRule].self, forKey: .customRules) ?? d.customRules

        if let list = try c.decodeIfPresent([SubscriptionEntry].self, forKey: .subscriptions), !list.isEmpty {
            subscriptions = list
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .subscriptionURL),
                  !legacy.trimmingCharacters(in: .whitespaces).isEmpty {
            // 旧版单链接 → 一条默认订阅
            subscriptions = [
                SubscriptionEntry(id: "legacy", name: "默认订阅", url: legacy, enabled: true, lastNodeCount: nil)
            ]
        } else {
            subscriptions = d.subscriptions
        }
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
        ipv6: false
        unified-delay: true
        tcp-concurrent: true
        find-process-mode: "off"

        profile:
          store-selected: true
          store-fake-ip: true

        # TUN + fake-ip：节点 server 域名必须走 proxy-server-nameserver，
        # 否则会和 fake-ip 劫持打架 → dial dns resolve failed / curl Empty reply。
        dns:
          enable: true
          ipv6: false
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          fake-ip-filter:
            - '*.lan'
            - '*.local'
            - 'time.*.com'
            - 'ntp.*.com'
            - 'stun.*.*'
          default-nameserver:
            - 223.5.5.5
            - 8.8.8.8
          nameserver:
            - https://223.5.5.5/dns-query
            - https://1.1.1.1/dns-query
          fallback:
            - https://8.8.8.8/dns-query
            - tls://1.1.1.1
          fallback-filter:
            geoip: true
            geoip-code: CN
          proxy-server-nameserver:
            - https://223.5.5.5/dns-query
            - 8.8.8.8
          direct-nameserver:
            - system

        """

        if s.tunEnabled {
            yaml += """

            tun:
              enable: true
              stack: mixed
              auto-route: true
              auto-detect-interface: true
              strict-route: false
              dns-hijack:
                - any:53

            """
        }

        let active = s.activeSubscriptions
        let customRuleLines = s.customRules
            .filter(\.enabled)
            .compactMap(\.clashLine)

        if active.isEmpty {
            yaml += """

            proxy-groups:
              - name: PROXY
                type: select
                proxies:
                  - DIRECT

            """
            // 规则段单独拼行：Swift 多行字符串会丢掉结尾换行，
            // 写成 `rules:\n"""` + `"""\n  - …` 会粘成 `rules:  - …` 导致 YAML 解析失败。
            yaml += "rules:\n"
            for line in customRuleLines {
                yaml += "  - \(line)\n"
            }
            yaml += "  - MATCH,PROXY\n"
        } else {
            // 每条订阅一个 file provider；内容由 SubscriptionFetcher 落盘。
            yaml += "\nproxy-providers:\n"
            for sub in active {
                yaml += """
                  \(sub.providerName):
                    type: file
                    path: ./providers/\(sub.id).yaml
                    health-check:
                      enable: true
                      interval: 300
                      url: https://www.gstatic.com/generate_204

                """
            }

            let useList = active.map { "      - \($0.providerName)" }.joined(separator: "\n")
            yaml += """
            proxy-groups:
              - name: 🚀 节点选择
                type: select
                proxies:
                  - ♻️ 自动选择
                  - DIRECT
                use:
            \(useList)
              - name: ♻️ 自动选择
                type: url-test
                tolerance: 50
                url: https://www.gstatic.com/generate_204
                interval: 300
                use:
            \(useList)

            """
            yaml += "rules:\n"
            for line in customRuleLines {
                yaml += "  - \(line)\n"
            }
            yaml += "  - GEOIP,LAN,DIRECT,no-resolve\n"
            yaml += "  - GEOIP,CN,DIRECT\n"
            yaml += "  - MATCH,🚀 节点选择\n"
        }

        try yaml.write(to: Paths.generatedConfig, atomically: true, encoding: .utf8)
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
