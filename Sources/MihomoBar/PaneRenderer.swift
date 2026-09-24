import SwiftUI
import AppKit

/// 离屏渲染每个页面，确认它们都能画出来。
///
///     MihomoBar --render-panes [输出目录]
///
/// 存在的意义：主窗口一次只显示一个页面，其余几个只有用户点开才会构建视图。
/// 如果某个页面在数据为空、内核未运行等状态下会崩，光看当前界面是发现不了的。
/// 这里把六个视图各渲染一遍并落盘，顺便统计尺寸与非空率。
@MainActor
enum PaneRenderer {

    static func run(outputDirectory: String?) {
        let outDir = outputDirectory ?? NSTemporaryDirectory() + "mihomobar-panes"
        try? FileManager.default.createDirectory(atPath: outDir,
                                                 withIntermediateDirectories: true)

        let model = AppModel()
        let size = NSSize(width: 880, height: 620)

        let panes: [(String, AnyView)] = [
            ("1-overview",     AnyView(OverviewPane(model: model))),
            ("2-proxies",      AnyView(ProxiesPane(model: model))),
            ("3-connections",  AnyView(ConnectionsPane(model: model))),
            ("4-rules",        AnyView(RulesPane(model: model))),
            ("5-subscription", AnyView(SubscriptionPane(model: model))),
            ("6-logs",         AnyView(LogsPane(model: model))),
            ("7-settings",     AnyView(SettingsPane(model: model))),
        ]

        print("离屏渲染检查（内核未运行状态 —— 最容易踩空数据崩溃的场景）")
        print("───────────────────────────────────────")
        var failures = 0

        for (name, view) in panes {
            let frame = NSRect(origin: .zero, size: size)

            let hosting = NSHostingView(rootView: view)
            hosting.frame = frame
            hosting.layoutSubtreeIfNeeded()

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("  ❌ \(name)  无法创建位图")
                failures += 1
                continue
            }
            // 离屏位图默认是透明的。先填窗口背景色，一是让落盘的 PNG 能看，
            // 二是避免用颜色差异判断内容时把「透明背景 + 深色文字」当成空白。
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: frame.size).fill()
            NSGraphicsContext.restoreGraphicsState()

            hosting.cacheDisplay(in: hosting.bounds, to: rep)

            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("  ❌ \(name)  PNG 编码失败")
                failures += 1
                continue
            }
            let path = "\(outDir)/\(name).png"
            try? png.write(to: URL(fileURLWithPath: path))

            let stats = analyse(rep)
            // 结构性判定而不是单一百分比：
            // 「节点」页在内核未运行时只有一个标题加一小块空状态，
            // 总体占比不到 1% 但渲染完全正常。
            let ok = stats.header > 0.002 && stats.body > 0.002
            if ok {
                print("  ✅ \(name)  \(Int(frame.width))×\(Int(frame.height)) "
                      + "标题区 \(String(format: "%.1f%%", stats.header * 100)) "
                      + "内容区 \(String(format: "%.1f%%", stats.body * 100))")
            } else {
                print("  ❌ \(name)  渲染异常 "
                      + "（标题区 \(String(format: "%.2f%%", stats.header * 100)) / "
                      + "内容区 \(String(format: "%.2f%%", stats.body * 100))）")
                failures += 1
            }
        }

        print("───────────────────────────────────────")
        print(failures == 0 ? "全部渲染成功，输出在 \(outDir)" : "\(failures) 个页面渲染异常")
        exit(failures == 0 ? 0 : 1)
    }

    /// 渲染结果的结构统计。
    /// 位图已预先填过窗口背景色，所以直接和该背景色比对。
    private struct RenderStats {
        let header: Double   // 顶部 20% 的内容占比
        let body: Double     // 其余 80% 的内容占比
        let total: Double
    }

    private static func analyse(_ rep: NSBitmapImageRep) -> RenderStats {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return RenderStats(header: 0, body: 0, total: 0) }

        // ⚠️ NSColor.windowBackgroundColor 是动态目录色，
        // 直接调 redComponent 会抛 NSException（不是可捕获的 Swift error）。
        // 必须先落到具体色彩空间。
        let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .white
        let br = bg.redComponent * 255, bgc = bg.greenComponent * 255, bb = bg.blueComponent * 255
        let threshold = 18.0

        let headerCut = h / 5
        var headTotal = 0, headHit = 0, bodyTotal = 0, bodyHit = 0

        for y in stride(from: 0, to: h, by: max(1, h / 200)) {
            for x in stride(from: 0, to: w, by: max(1, w / 200)) {
                guard let raw = rep.colorAt(x: x, y: y),
                      let c = raw.usingColorSpace(.sRGB) else { continue }
                let r = c.redComponent * 255, g = c.greenComponent * 255, b = c.blueComponent * 255
                let hit = abs(r - br) + abs(g - bgc) + abs(b - bb) > threshold
                if y < headerCut {
                    headTotal += 1
                    if hit { headHit += 1 }
                } else {
                    bodyTotal += 1
                    if hit { bodyHit += 1 }
                }
            }
        }

        let header = headTotal > 0 ? Double(headHit) / Double(headTotal) : 0
        let body = bodyTotal > 0 ? Double(bodyHit) / Double(bodyTotal) : 0
        let total = (headTotal + bodyTotal) > 0
            ? Double(headHit + bodyHit) / Double(headTotal + bodyTotal) : 0
        return RenderStats(header: header, body: body, total: total)
    }
}
