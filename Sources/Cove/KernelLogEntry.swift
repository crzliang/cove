import Foundation

/// 解析 mihomo / 应用写入的一行日志。
struct KernelLogEntry: Identifiable, Equatable {
    let id: Int
    /// `14:12:36`，解析不到就空。
    let timeText: String
    /// info / warning / error / debug
    let level: String
    /// tcp / udp / tun / dns / system
    let category: String
    let message: String
    let raw: String

    var levelLabel: String { level }

    static func parseLines(_ text: String) -> [KernelLogEntry] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [KernelLogEntry] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let entry = parseMihomo(trimmed, id: index, raw: raw) {
                result.append(entry)
            } else if let entry = parseApp(trimmed, id: index, raw: raw) {
                result.append(entry)
            } else {
                result.append(KernelLogEntry(
                    id: index,
                    timeText: "",
                    level: "info",
                    category: "system",
                    message: trimmed,
                    raw: raw))
            }
        }
        return result
    }

    /// `time="…+08:00" level=info msg="…"`
    private static func parseMihomo(_ line: String, id: Int, raw: String) -> KernelLogEntry? {
        // "time=\"" 共 6 个字符，从时间内容开始找结束引号。
        guard line.hasPrefix("time=\""),
              line.count > 6 else { return nil }
        let timeStart = line.index(line.startIndex, offsetBy: 6)
        guard let timeEnd = line[timeStart...].firstIndex(of: "\""),
              let levelKey = line.range(of: " level="),
              let msgKey = line.range(of: " msg=\"") else { return nil }

        let timeRaw = String(line[timeStart..<timeEnd])
        let afterLevel = line[levelKey.upperBound...]
        let level = String(afterLevel.prefix(while: { $0.isLetter })).lowercased()
        guard !level.isEmpty else { return nil }

        let msgStart = msgKey.upperBound
        var message = String(line[msgStart...])
        if message.hasSuffix("\"") {
            message.removeLast()
        }
        message = message
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")

        return KernelLogEntry(
            id: id,
            timeText: shortTime(timeRaw),
            level: level,
            category: category(of: message),
            message: message,
            raw: raw)
    }

    /// `[2026-09-29T06:11:31Z] === start …`
    private static func parseApp(_ line: String, id: Int, raw: String) -> KernelLogEntry? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else { return nil }
        let stamp = String(line[line.index(after: line.startIndex)..<close])
        let message = line[line.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return nil }
        return KernelLogEntry(
            id: id,
            timeText: shortTime(stamp),
            level: "info",
            category: "system",
            message: message,
            raw: raw)
    }

    private static func category(of message: String) -> String {
        if message.hasPrefix("[TCP]") { return "tcp" }
        if message.hasPrefix("[UDP]") { return "udp" }
        if message.hasPrefix("[TUN]") { return "tun" }
        if message.hasPrefix("[DNS]") || message.contains("DNS") && message.hasPrefix("[") {
            return "dns"
        }
        return "system"
    }

    private static func shortTime(_ raw: String) -> String {
        // 2026-09-29T14:11:42.656230000+08:00 / 2026-09-29T06:11:31Z
        if let t = raw.firstIndex(of: "T") {
            let rest = raw[raw.index(after: t)...]
            let end = rest.firstIndex(where: { $0 == "." || $0 == "+" || $0 == "Z" }) ?? rest.endIndex
            let hm = String(rest[..<end])
            if hm.count >= 8 { return String(hm.prefix(8)) }
            return hm
        }
        return ""
    }
}

enum KernelLogFilter {
    static let levels = ["all", "info", "warning", "error", "debug"]
    static let categories = ["all", "connection", "tun", "dns", "system"]

    static func levelTitle(_ value: String) -> String {
        switch value {
        case "all": return "全部级别"
        default: return value
        }
    }

    static func categoryTitle(_ value: String) -> String {
        switch value {
        case "all": return "全部"
        case "connection": return "连接"
        case "tun": return "TUN"
        case "dns": return "DNS"
        case "system": return "系统"
        default: return value
        }
    }

    static func matches(_ entry: KernelLogEntry,
                        level: String,
                        category: String,
                        search: String) -> Bool {
        if level != "all", entry.level != level { return false }
        switch category {
        case "all": break
        case "connection":
            if entry.category != "tcp" && entry.category != "udp" { return false }
        default:
            if entry.category != category { return false }
        }

        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        // 普通搜索走 contains；带正则元字符时再编译，避免每行都 try Regex。
        if q.unicodeScalars.contains(where: { Self.regexMeta.contains($0) }),
           let re = try? NSRegularExpression(pattern: q, options: [.caseInsensitive]) {
            let range = NSRange(entry.raw.startIndex..<entry.raw.endIndex, in: entry.raw)
            return re.firstMatch(in: entry.raw, options: [], range: range) != nil
        }
        return entry.raw.localizedCaseInsensitiveContains(q)
    }

    private static let regexMeta: Set<Unicode.Scalar> = [
        ".", "*", "+", "?", "[", "]", "(", ")", "{", "}", "^", "$", "|", "\\",
    ]
}
