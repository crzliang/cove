import AppKit

/// 菜单栏图标，和应用图标是同一套三点网络。
///
/// 画成模板图（只有透明度），亮色/暗色菜单栏都会自动适配。
enum MenuBarIcon {

    static func image(dimmed: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(dimmed: dimmed, side: side)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(dimmed: Bool, side: CGFloat) {
        // 坐标来自 AppIcon.svg，原点在图形中心，y 向上（已从 SVG 翻转）。
        let nodes: [(CGFloat, CGFloat, CGFloat)] = [
            (-170, -120, 58),
            (170, -120, 58),
            (0, 150, 72),
        ]
        let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-170, -120, 0, 150),
            (170, -120, 0, 150),
            (-170, -120, 170, -120),
        ]
        let minX: CGFloat = -228
        let maxX: CGFloat = 228
        let minY: CGFloat = -178
        let maxY: CGFloat = 222
        let pad: CGFloat = 0.5
        let avail = side - pad * 2
        let scale = min(avail / (maxX - minX), avail / (maxY - minY))
        let originX = pad + (avail - (maxX - minX) * scale) / 2
        let originY = pad + (avail - (maxY - minY) * scale) / 2

        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + (x - minX) * scale,
                    y: originY + (y - minY) * scale)
        }

        let color = NSColor.black.withAlphaComponent(dimmed ? 0.4 : 1)
        color.setStroke()
        color.setFill()

        for (x1, y1, x2, y2) in lines {
            let path = NSBezierPath()
            path.lineWidth = 26 * scale
            path.lineCapStyle = .round
            path.move(to: map(x1, y1))
            path.line(to: map(x2, y2))
            path.stroke()
        }
        for (x, y, r) in nodes {
            let c = map(x, y)
            let radius = r * scale
            NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                         width: radius * 2, height: radius * 2)).fill()
        }
    }
}
