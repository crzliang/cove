import Foundation

/// `mihomo -v` 输出解析。
///
/// 原始两行是这样的：
///
///     Mihomo Meta v1.19.21 darwin arm64 with go1.24.13 Mon Mar 9 16:55:59 UTC 2026
///     Use tags: with_gvisor
///
/// 直接铺在界面上是 88 个字符的一整行（实测横跨窗口 44% 宽度），挤在一起没法读。
/// 这里拆成结构化字段，各处按需要取用。
struct KernelVersion: Equatable {

    let product: String        // "Mihomo Meta"
    let version: String        // "1.19.21"
    let os: String             // "darwin"
    let arch: String           // "arm64"
    let goVersion: String      // "go1.24.13"
    let buildTime: String?     // "2026-03-09 16:55:59 UTC"
    let tags: [String]         // ["with_gvisor"]

    /// 概览页副标题：只保留最需要一眼看到的两项
    var short: String { "\(product) v\(version)" }

    /// 平台一行
    var platform: String { "\(os) \(arch) · \(goVersion)" }

    /// 解析失败时的兜底：原样保留，不要因为解析不出来就丢信息
    static func parse(_ raw: String) -> KernelVersion? {
        let lines = raw.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let first = lines.first, !first.isEmpty else { return nil }

        // 用正则而不是按空格切 —— 构建时间里本身含空格
        // （"Mon Mar 9 16:55:59 UTC 2026"），切了就散。
        let pattern = #"^(.+?)\s+v?(\d+(?:\.\d+)*)\s+(\S+)\s+(\S+)\s+with\s+(\S+)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: first,
                                           range: NSRange(first.startIndex..., in: first)),
              match.numberOfRanges == 7 else {
            return nil
        }

        func group(_ i: Int) -> String {
            guard let r = Range(match.range(at: i), in: first) else { return "" }
            return String(first[r])
        }

        var tags: [String] = []
        for line in lines.dropFirst() where line.lowercased().hasPrefix("use tags:") {
            let list = line.dropFirst("Use tags:".count)
            tags = list.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        return KernelVersion(
            product: group(1),
            version: group(2),
            os: group(3),
            arch: group(4),
            goVersion: group(5),
            buildTime: normalizeBuildTime(group(6)),
            tags: tags
        )
    }

    /// `Mon Mar 9 16:55:59 UTC 2026` → `2026-03-09 16:55:59 UTC`
    /// 丢掉星期几，并把月和日补零，便于对齐阅读。
    private static func normalizeBuildTime(_ raw: String) -> String? {
        let parts = raw.split(separator: " ").map(String.init)
        guard parts.count >= 6 else { return raw.isEmpty ? nil : raw }

        let months = ["Jan": "01", "Feb": "02", "Mar": "03", "Apr": "04",
                      "May": "05", "Jun": "06", "Jul": "07", "Aug": "08",
                      "Sep": "09", "Oct": "10", "Nov": "11", "Dec": "12"]
        // parts: [Weekday, Mon, Day, Time, TZ, Year]
        guard let month = months[parts[1]] else { return raw }
        let day = String(format: "%02d", Int(parts[2]) ?? 0)
        return "\(parts[5])-\(month)-\(day) \(parts[3]) \(parts[4])"
    }
}
