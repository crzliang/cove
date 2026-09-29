import Foundation

/// 从订阅落盘文件里抽出 `proxy-groups`，供生成配置复用。
///
/// Mihomo 的 file provider 只吃 `proxies:`，策略组必须写进主配置；
/// 以前只生成「节点选择 / 自动选择」两个组，订阅里的分流组全部被丢掉了。
enum SubscriptionProxyGroups {

    struct Group {
        var name: String
        /// 已缩进到主配置 `proxy-groups:` 下的完整 YAML 块（以 `  - ` 开头）。
        var yaml: String
    }

    /// 读取 `./providers/<id>.yaml` 的策略组；没有则返回空。
    static func load(from file: URL, providerName: String) -> [Group] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        guard let section = extractSection(from: text) else { return [] }
        return parseGroups(section, providerName: providerName)
    }

    /// 选出 MATCH 应落到的组名。
    static func preferredMatchName(in groups: [Group]) -> String {
        let names = groups.map(\.name)
        if let hit = names.first(where: { $0.contains("节点选择") }) { return hit }
        if let hit = names.first(where: { $0.localizedCaseInsensitiveContains("proxy") }) { return hit }
        return names.first ?? "PROXY"
    }

    // MARK: - Parse

    private static func extractSection(from text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "proxy-groups:" }) else {
            return nil
        }
        var end = lines.count
        if start + 1 < lines.count {
            for i in (start + 1)..<lines.count {
                let line = String(lines[i])
                // 下一个顶层键（行首无缩进、以 key: 结尾）
                if let first = line.unicodeScalars.first,
                   !CharacterSet.whitespacesAndNewlines.contains(first),
                   line.contains(":"),
                   !line.hasPrefix("#") {
                    end = i
                    break
                }
            }
        }
        let body = lines[(start + 1)..<end].map(String.init)
        let joined = body.joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
    }

    private static func parseGroups(_ section: String, providerName: String) -> [Group] {
        let lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 策略组条目的公共缩进：第一个以 `- ` 开头的列表项
        guard let probe = lines.first(where: { trimmedListItem($0) != nil }),
              let itemIndent = probe.firstIndex(where: { !$0.isWhitespace }).map({ probe.distance(from: probe.startIndex, to: $0) })
        else { return [] }

        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            let indent = line.firstIndex(where: { !$0.isWhitespace }).map { line.distance(from: line.startIndex, to: $0) } ?? line.count
            if indent == itemIndent, trimmedListItem(line) != nil {
                if !current.isEmpty { blocks.append(current) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        var result: [Group] = []
        result.reserveCapacity(blocks.count)
        let knownNames = Set(blocks.compactMap { groupName(in: $0) })
        for block in blocks {
            guard let name = groupName(in: block) else { continue }
            let adapted = ensureUse(block,
                                    providerName: providerName,
                                    itemIndent: itemIndent,
                                    knownGroupNames: knownNames)
            let reindented = reindent(adapted, from: itemIndent, to: 2)
            result.append(Group(name: name, yaml: reindented.joined(separator: "\n")))
        }
        return result
    }

    private static func trimmedListItem(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- ") || t == "-" else { return nil }
        return t
    }

    private static func groupName(in lines: [String]) -> String? {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            let raw: String
            if t.hasPrefix("- name:") {
                raw = String(t.dropFirst("- name:".count))
            } else if t.hasPrefix("name:") {
                raw = String(t.dropFirst("name:".count))
            } else {
                continue
            }
            return unquote(raw.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.count >= 2 {
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                s.removeFirst(); s.removeLast()
            }
        }
        // 订阅里常见 "\U0001F680 节点选择"
        if s.contains("\\U") || s.contains("\\u") {
            var out = ""
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "\\", s.index(i, offsetBy: 1, limitedBy: s.endIndex).map({ s[$0] == "U" || s[$0] == "u" }) == true {
                    let isLong = s[s.index(after: i)] == "U"
                    let hexLen = isLong ? 8 : 4
                    let hexStart = s.index(i, offsetBy: 2)
                    guard let hexEnd = s.index(hexStart, offsetBy: hexLen, limitedBy: s.endIndex),
                          let scalar = UInt32(s[hexStart..<hexEnd], radix: 16),
                          let uni = UnicodeScalar(scalar) else {
                        out.append(s[i]); i = s.index(after: i); continue
                    }
                    out.append(Character(uni))
                    i = hexEnd
                } else {
                    out.append(s[i])
                    i = s.index(after: i)
                }
            }
            return out
        }
        return s
    }

    /// 没有 `use` / `include-all` 时补上 provider，否则组内节点名解析不到。
    ///
    /// 另外：`proxies:` 里的节点名不会去 provider 里解析，只认主配置里的
    /// proxies / 其他策略组。所以属于节点的项要删掉，改由 `use` 引入。
    private static func ensureUse(_ lines: [String],
                                  providerName: String,
                                  itemIndent: Int,
                                  knownGroupNames: Set<String>) -> [String] {
        let fieldPad = String(repeating: " ", count: itemIndent + 2)
        let listPad = String(repeating: " ", count: itemIndent + 4)

        var hasUse = false
        var hasIncludeAll = false
        var proxyStart: Int?
        var proxyIndices: [Int] = []
        var keptProxyLines: [String] = []

        for (idx, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "use:" || t.hasPrefix("use:") { hasUse = true }
            if t.hasPrefix("include-all") { hasIncludeAll = true }
            if t == "proxies:" || t.hasPrefix("proxies:") {
                proxyStart = idx
                continue
            }
            if let start = proxyStart, idx > start {
                let indent = line.firstIndex(where: { !$0.isWhitespace }).map { line.distance(from: line.startIndex, to: $0) } ?? 0
                if !t.isEmpty, !t.hasPrefix("-"), indent <= itemIndent + 2 {
                    proxyStart = nil
                } else if t.hasPrefix("-") {
                    proxyIndices.append(idx)
                    let value = unquote(String(t.drop(while: { $0 == "-" || $0.isWhitespace })))
                    if shouldKeepProxyRef(value, knownGroupNames: knownGroupNames) {
                        keptProxyLines.append("\(listPad)- \(quoteIfNeeded(value))")
                    }
                }
            }
        }

        var out: [String] = []
        let drop = Set(proxyIndices)
        var skippingProxyList = false
        for (idx, line) in lines.enumerated() {
            if drop.contains(idx) { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "proxies:" || t.hasPrefix("proxies:") {
                if keptProxyLines.isEmpty {
                    skippingProxyList = true
                    continue
                }
                skippingProxyList = false
                out.append("\(fieldPad)proxies:")
                out.append(contentsOf: keptProxyLines)
                continue
            }
            if skippingProxyList {
                // `proxies: null` 单行已在上面处理；列表项已被 drop。
                skippingProxyList = false
            }
            out.append(line)
        }

        if hasIncludeAll {
            return out
        }
        if !hasUse {
            out.append("\(fieldPad)use:")
            out.append("\(fieldPad)  - \(providerName)")
        }
        return out
    }

    private static func shouldKeepProxyRef(_ name: String, knownGroupNames: Set<String>) -> Bool {
        let builtIn: Set<String> = [
            "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL",
        ]
        if builtIn.contains(name) { return true }
        if knownGroupNames.contains(name) { return true }
        // 兼容未解码的 \UXXXX 名称：对 known 再比一次原始串无必要，unquote 已解码。
        return false
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        let special = value.contains(":") || value.contains("#") || value.contains("{")
            || value.contains("}") || value.contains("[") || value.contains("]")
            || value.contains(",") || value.contains("&") || value.contains("*")
            || value.contains("!") || value.contains("%") || value.contains("@")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.contains("\"")
        if special || value.hasPrefix("'") {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func reindent(_ lines: [String], from old: Int, to new: Int) -> [String] {
        let delta = new - old
        return lines.map { line in
            guard let idx = line.firstIndex(where: { !$0.isWhitespace }) else {
                return line
            }
            let indent = line.distance(from: line.startIndex, to: idx)
            let next = max(0, indent + delta)
            return String(repeating: " ", count: next) + String(line[idx...])
        }
    }
}
