import AppKit

/// 把菜单栏下拉菜单按当前状态构造一遍并打印。
///
///     MihomoBar --dump-menu [stopped|running]
///
/// 菜单是 `menuNeedsUpdate` 里按状态动态重建的，光看代码不容易发现漏项或状态
/// 判断写反。这里在一个真实的 NSMenu 上跑一遍，把结果打出来。
/// 不需要点开界面，也绕开了辅助功能权限。
@MainActor
enum MenuDump {

    static func run(_ args: [String]) {
        let delegate = AppDelegate()

        // 可选：先把内核跑起来，看「运行中」状态下的菜单
        let wantsRunning = args.contains("running")
        let done = DispatchSemaphore(value: 0)

        Task { @MainActor in
            if wantsRunning {
                if let binary = try? Bundled.ensureKernel(),
                   let config = try? ConfigWriter.resolvedConfig(for: Settings()) {
                    await delegate.kernelForDump.start(config: config, binary: binary,
                                                       dataDir: Paths.dataDir, uiDir: nil,
                                                       privileged: false)
                }
            }
            delegate.syncStatusForDump()
            printMenu(delegate)
            if wantsRunning { delegate.kernelForDump.stop() }
            done.signal()
        }
        // 等 Task 跑完（RunLoop 驱动，避免死等）
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }

    private static func printMenu(_ delegate: AppDelegate) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        delegate.menuNeedsUpdate(menu)

        print("菜单栏下拉菜单（\(delegate.dumpState)）")
        print("───────────────────────────────────────")
        for item in menu.items {
            if item.isSeparatorItem {
                print("  ──────────")
                continue
            }
            var marks: [String] = []
            if item.state == .on { marks.append("✓") }
            if !item.isEnabled { marks.append("灰") }
            if item.submenu != nil { marks.append("▸") }
            if !item.keyEquivalent.isEmpty { marks.append("⌘\(item.keyEquivalent.uppercased())") }
            let suffix = marks.isEmpty ? "" : "   [" + marks.joined(separator: " ") + "]"
            print("  \(item.title)\(suffix)")
            if let sub = item.submenu {
                for child in sub.items where !child.isSeparatorItem {
                    let on = child.state == .on ? " ✓" : ""
                    print("      · \(child.title)\(on)")
                }
            }
        }
        print("───────────────────────────────────────")
        print("共 \(menu.items.filter { !$0.isSeparatorItem }.count) 个可用条目")
    }
}
