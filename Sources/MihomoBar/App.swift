import AppKit

/// 入口。
///
/// 用 `@main` 而不是 `main.swift` 顶层代码：顶层语句不是 MainActor 隔离的，
/// 无法直接构造 `@MainActor` 的 AppDelegate。`@main` 下可以显式标注，
/// 且在 SwiftPM / Xcode 两种构建方式下行为一致。
@main
struct MihomoBarApp {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if HelperCLI.run(args) { return }
        if args.contains("--render-panes") {
            let index = args.firstIndex(of: "--render-panes")!
            let dir = index + 1 < args.count && !args[index + 1].hasPrefix("--")
                ? args[index + 1] : nil
            PaneRenderer.run(outputDirectory: dir)
            return
        }
        if args.contains("--selftest") {
            SelfTest.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate      // AppKit 的 delegate 是 weak，delegate 变量需在本作用域存活
        app.run()
    }
}
