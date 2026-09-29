import Foundation

/// 所有应用私有路径。
///
/// 设计约束：**永不写入用户自己的 Clash 配置**。
/// 内核启动参数全部通过命令行注入（`-ext-ctl` / `-ext-ui` / `-secret`），
/// 用户提供的配置以只读方式传给 `-f`。
enum Paths {

    /// ~/Library/Application Support/Cove
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Cove", isDirectory: true)
    }()

    /// 旧版 MihomoBar 数据目录。
    static let legacyRoot: URL = {
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

    /// 某条订阅的落盘位置（相对内核 `-d` 即 `./providers/<id>.yaml`）
    static func subscriptionFile(id: String) -> URL {
        dataDir.appendingPathComponent("providers/\(id).yaml")
    }

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
        migrateFromLegacyIfNeeded()
        let fm = FileManager.default
        for dir in [root, dataDir, dataDir.appendingPathComponent("providers", isDirectory: true)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 从旧版 Application Support/MihomoBar 迁到 Cove。
    /// Cove 已存在但没有订阅缓存时，也会把旧订阅和设置合过来。
    private static func migrateFromLegacyIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyRoot.path) else { return }

        if !fm.fileExists(atPath: root.path) {
            do {
                try fm.moveItem(at: legacyRoot, to: root)
            } catch {
                NSLog("[Cove] 迁移旧数据失败：\(error)")
            }
            return
        }

        let legacyProviders = legacyRoot.appendingPathComponent("data/providers", isDirectory: true)
        let coveProviders = dataDir.appendingPathComponent("providers", isDirectory: true)
        let legacyHasSubs = !((try? fm.contentsOfDirectory(atPath: legacyProviders.path)) ?? []).isEmpty
        let coveHasSubs = !((try? fm.contentsOfDirectory(atPath: coveProviders.path)) ?? []).isEmpty
        // 已经有订阅就不动；仅在 Cove 还是空壳时合并
        guard legacyHasSubs else { return }
        if coveHasSubs { return }

        do {
            try fm.createDirectory(at: coveProviders, withIntermediateDirectories: true)
            for name in ["settings.json", "generated.yaml", "dns.backup.json"] {
                let src = legacyRoot.appendingPathComponent(name)
                let dst = root.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
            for file in try fm.contentsOfDirectory(at: legacyProviders, includingPropertiesForKeys: nil) {
                let dst = coveProviders.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: file, to: dst)
            }
            let legacyData = legacyRoot.appendingPathComponent("data", isDirectory: true)
            for name in ["geoip.metadb", "geosite.dat", "GeoSite.dat", "country.mmdb", "cache.db"] {
                let src = legacyData.appendingPathComponent(name)
                let dst = dataDir.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                try fm.copyItem(at: src, to: dst)
            }
            NSLog("[Cove] 已从 MihomoBar 合并订阅与设置")
        } catch {
            NSLog("[Cove] 合并旧数据失败：\(error)")
        }
    }
}
