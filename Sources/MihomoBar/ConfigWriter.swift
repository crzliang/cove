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
    /// 是否在 Dock 中显示图标。关掉就退化成纯菜单栏应用。
    var showInDock: Bool = true
    /// 启动时是否自动打开主窗口。
    ///
    /// 不用启发式判断「是不是开机自启拉起的」—— 试过两条路都不行：
    /// `NSAppleEventManager.currentAppleEvent`（open 启动时为 nil）和
    /// `NSApplicationLaunchIsDefaultLaunchKey`（终端启动时也是 false，实测确认）。
    /// 与其瞎猜，不如给用户一个开关；开启「开机自启」时会自动关掉它。
    var showWindowOnLaunch: Bool = true

    /// 窗口位置是否由**用户拖动**决定过。
    ///
    /// 不用这个标记的话会有个鸡生蛋问题：应用自己把窗口放到某个位置 → 自动保存 →
    /// 下次启动“恢复”到那个位置。实测就是窗口反复出现在第二块屏幕上（用户从没放过）。
    /// 只有用户真正拖过窗口，才尊重保存的坐标。
    var windowPositionIsUserChosen: Bool = false

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settings) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
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
        case subscriptionURL, mixedPort, tunEnabled, mode, logLevel
        case customConfigPath, showInDock, windowPositionIsUserChosen
        case showWindowOnLaunch
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
        subscriptionURL  = try c.decodeIfPresent(String.self, forKey: .subscriptionURL)  ?? d.subscriptionURL
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
    }
}

/// 生成内核配置。
///
/// 关键约束：**永远不写入、不修改用户自己的配置文件**。
/// 用户若指定了 `customConfigPath`，那份文件以只读方式经 `-f` 传给内核；
/// 否则这里生成一份应用自有的 `generated.yaml`。
enum ConfigWriter {

    /// `proxy-providers` 里订阅的名字。CtlClient 刷新订阅时要用同一个名字。
    static let providerName = "sub"

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
              \(providerName):
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
                  - \(providerName)
              - name: ♻️ 自动选择
                type: url-test
                tolerance: 50
                url: https://www.gstatic.com/generate_204
                interval: 300
                use:
                  - \(providerName)

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
