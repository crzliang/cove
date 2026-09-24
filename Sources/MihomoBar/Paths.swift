import Foundation

/// 所有应用私有路径。
///
/// 设计约束：**永不写入用户自己的 Clash 配置**。
/// 内核启动参数全部通过命令行注入（`-ext-ctl` / `-ext-ui` / `-secret`），
/// 用户提供的配置以只读方式传给 `-f`。
enum Paths {

    /// ~/Library/Application Support/MihomoBar
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("MihomoBar", isDirectory: true)
    }()

    /// 应用自己生成的内核配置（用户配置另存，不受影响）
    static var generatedConfig: URL { root.appendingPathComponent("generated.yaml") }

    /// 内核 stdout+stderr 追加写入。实测 mihomo 日志走 stdout，不是 stderr。
    static var kernelLog: URL { root.appendingPathComponent("mihomo.log") }

    /// 内核工作目录（放 cache.db / Country.mmdb / geosite.dat / providers/）
    static var dataDir: URL { root.appendingPathComponent("data", isDirectory: true) }

    /// MetaCubeXD 静态文件
    static var uiDir: URL { dataDir.appendingPathComponent("ui", isDirectory: true) }

    /// 从 app bundle 复制出来的可写内核副本
    static var kernelBinary: URL { root.appendingPathComponent("mihomo") }

    /// 当前运行实例的端口与 secret，供外部工具读取
    static var runtimeInfo: URL { root.appendingPathComponent("runtime.json") }

    /// 订阅链接等用户设置
    static var settings: URL { root.appendingPathComponent("settings.json") }

    /// 内核 unix socket。注意：内核退出后不会自行删除，需应用侧清理。
    static var controlSocket: URL { root.appendingPathComponent("ctl.sock") }

    static func ensureDirs() throws {
        let fm = FileManager.default
        for dir in [root, dataDir, dataDir.appendingPathComponent("providers", isDirectory: true)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
