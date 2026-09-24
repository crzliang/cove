import Foundation

/// 定位随 app 一起分发的 mihomo 内核与 MetaCubeXD。
///
/// 内核不能直接从 bundle 里执行（只读、且被公证/签名后更不可写），
/// 所以第一次启动时复制一份到 Application Support，之后都跑那份副本
/// （内核更新也只需替换副本）。
enum Bundled {

    /// 在可执行文件附近查找资源，兼容三种运行方式：
    /// 1. `swift run` / `swift build`：`.build/<config>/MihomoBar` 旁边
    /// 2. 手工组装的 .app：`Foo.app/Contents/MacOS/MihomoBar` → `Contents/Resources`
    /// 3. 开发时用 `MIHOMOBAR_RESOURCES=<dir>` 指定资源目录
    ///
    /// `isDirectory` 用来区分同名文件与目录 —— 否则 `MIHOMOBAR_RESOURCES=./Resources`
    /// 时会把 `Resources/` 目录本身当成 `mihomo` 命中。
    static func resourceURL(_ name: String, isDirectory: Bool) -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let exeDir = exe.deletingLastPathComponent()

        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MIHOMOBAR_RESOURCES"] {
            candidates.append(URL(fileURLWithPath: env).appendingPathComponent(name))
        }
        candidates += [
            exeDir.appendingPathComponent(name),                                  // 同目录
            exeDir.deletingLastPathComponent().appendingPathComponent(name),      // ../name
            exeDir.deletingLastPathComponent()
                   .appendingPathComponent("Resources")
                   .appendingPathComponent(name),                                 // ../Resources/name（.app）
            exeDir.appendingPathComponent("Resources").appendingPathComponent(name),
        ]

        for c in candidates {
            var flag = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: c.path, isDirectory: &flag) else { continue }
            guard flag.boolValue == isDirectory else {
                continue   // 类型不符：是文件却要目录（或反之），跳过
            }
            return c
        }
        return nil
    }

    /// 确保 Application Support 里有一份可执行的内核副本。
    /// 如果 bundle 里的版本更新（mtime 不同），则替换副本。
    static func ensureKernel() throws -> URL {
        let dest = Paths.kernelBinary
        guard let src = resourceURL("mihomo", isDirectory: false) else {
            throw BundledError.kernelMissing
        }

        let fm = FileManager.default
        try Paths.ensureDirs()

        let srcDate = (try? fm.attributesOfItem(atPath: src.path)[.modificationDate]) as? Date
        let destDate = (try? fm.attributesOfItem(atPath: dest.path)[.modificationDate]) as? Date

        if destDate == nil || (srcDate != nil && destDate! < srcDate!) {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
        return dest
    }

    /// 把 MetaCubeXD 静态文件同步到 data 目录，用于 `-ext-ui`。
    static func ensureUI() throws -> URL? {
        guard let src = resourceURL("ui", isDirectory: true) else { return nil }
        let dest = Paths.uiDir
        let fm = FileManager.default

        if !fm.fileExists(atPath: dest.path) {
            try Paths.ensureDirs()
            try fm.copyItem(at: src, to: dest)
        }
        return dest
    }

    /// 内核版本字符串，例如 `Mihomo Meta v1.19.21 darwin arm64 ...`
    static func kernelVersion(binary: URL) -> String? {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["-v"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum BundledError: Error, CustomStringConvertible {
    case kernelMissing

    var description: String {
        switch self {
        case .kernelMissing:
            return """
            找不到 mihomo 内核。
            请把 mihomo 二进制放到项目 Resources/ 目录，或用环境变量指定：
              MIHOMOBAR_RESOURCES=/path/to/dir ./MihomoBar
            该目录下需要有 mihomo 和 ui/ 两项。
            """
        }
    }
}
