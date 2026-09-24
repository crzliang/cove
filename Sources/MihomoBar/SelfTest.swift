import Foundation
import AppKit

/// Headless 自检：`MihomoBar --selftest`
///
/// 无需点开界面即可验证「定位内核 → 生成配置 → 预检 → 启动 → 查 API → 优雅停止」
/// 这条完整链路。不做任何系统级改动（不碰系统代理、不动 TUN）。
enum SelfTest {

    @MainActor
    static func run() {
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                print(ok ? "  ✅ \(name)" : "  ❌ \(name) \(detail)")
                if !ok { failures += 1 }
            }

            print("MihomoBar self-test")
            print("───────────────────────────────────────")

            // 1. 资源定位
            let kernel: URL
            do {
                kernel = try Bundled.ensureKernel()
                check("定位内核", true, kernel.path)
                check("内核可执行", FileManager.default.isExecutableFile(atPath: kernel.path))
            } catch {
                check("定位内核", false, "\(error)")
                exit(1)
            }
            let ui = try? Bundled.ensureUI()
            check("定位 MetaCubeXD", ui != nil, ui?.path ?? "未找到（面板将不可用）")

            if let v = Bundled.kernelVersion(binary: kernel) {
                check("内核版本", true, v)
            } else {
                check("内核版本", false)
            }

            // 2. 配置生成（写进 Application Support，不碰任何用户文件）
            var settings = Settings()
            settings.mixedPort = 7890
            let config: URL
            do {
                config = try ConfigWriter.resolvedConfig(for: settings)
                check("生成配置", true, config.path)
            } catch {
                check("生成配置", false, "\(error)")
                exit(1)
            }

            // 3. 端口分配
            if let p = Kernel.findFreePort() {
                check("分配空闲端口", p > 1024 && p < 65536, ":\(p)")
            } else {
                check("分配空闲端口", false)
            }

            // 4. 启动前预检
            do {
                try Kernel.validate(config: config, binary: kernel, dataDir: Paths.dataDir)
                check("配置预检 (-t)", true)
            } catch {
                check("配置预检 (-t)", false, "\(error)")
            }

            // 5. 完整启动
            let k = Kernel()
            print("  … 启动内核")
            await k.start(config: config, binary: kernel, dataDir: Paths.dataDir,
                          uiDir: ui, privileged: false)
            guard k.status.isRunning else {
                check("内核启动", false, "\(k.lastError ?? "未知")")
                print("\n最近日志：\n\(k.tailLog(lines: 12))")
                exit(1)
            }
            check("内核启动", true, ":\(k.port)")
            check("非提权标记正确", !k.isPrivileged)

            // 6. 控制器 API
            guard let endpoint = k.endpoint else {
                check("控制器可达", false)
                exit(1)
            }
            let ctl = CtlClient(base: endpoint, secret: k.secret)
            do {
                let v = try await ctl.version()
                check("GET /version", true, v.version)

                let cfg = try await ctl.configs()
                check("GET /configs", true, "mode=\(cfg.mode ?? "?")")

                let proxies = try await ctl.proxies()
                let groups = proxies.filter { $0.value.all != nil }
                let nodes = proxies.filter { $0.value.all == nil && !["Direct","Reject","RejectDrop","Compatible","Pass"].contains($0.value.type) }
                check("GET /proxies", true, "\(groups.count) 个策略组 / \(nodes.count) 个节点")

                try await ctl.setMode("global")
                let after = try await ctl.configs()
                check("PATCH /configs 切模式", after.mode == "global", "mode=\(after.mode ?? "?")")
                try await ctl.setMode("rule")

                try await ctl.reloadConfig()
                check("PUT /configs 重载", true)

                // 订阅 provider 接口（没配订阅时也能调用，只是返回空字典）
                let providers = try await ctl.providers()
                check("GET /providers/proxies", true, "\(providers.count) 个 provider")
                check("provider 名字常量一致", ConfigWriter.providerName == "sub",
                      ConfigWriter.providerName)
            } catch {
                check("控制器 API", false, "\(error)")
            }

            // 7. 面板可访问
            if ui != nil {
                let probe = URL(string: "http://127.0.0.1:\(k.port)/ui/")!
                var req = URLRequest(url: probe)
                req.timeoutInterval = 5
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    check("MetaCubeXD 面板", true, probe.absoluteString)
                } else {
                    check("MetaCubeXD 面板", false, "未返回 200")
                }
            }

            // 8. 运行期信息文件
            let info = Paths.runtimeInfo
            check("runtime.json", FileManager.default.fileExists(atPath: info.path))
            if let raw = try? Data(contentsOf: info),
               let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                check("runtime.json privileged 字段", obj["privileged"] as? Bool == false)
                check("runtime.json 记录了 pid", (obj["pid"] as? Int ?? 0) > 0)
            }

            // 9. 提权启动机制。
            //    用无特权的 `sh -c` 跑**同一套命令构造**，不弹授权框，
            //    验证：命令拼接、pid 回显、非阻塞返回、存活检测、SIGTERM。
            check("shell 引号转义",
                  Privileged.shellQuote("a'b c") == "'a'\\''b c'",
                  Privileged.shellQuote("a'b c"))
            check("进程存活检测（自身）", Privileged.processExists(getpid()))
            check("进程存活检测（不存在的 pid）", !Privileged.processExists(999_999))
            check("开机自启可用性判断", LaunchAtLogin.isAvailable == Bundle.main.bundlePath.hasSuffix(".app"),
                  LaunchAtLogin.statusDescription)

            let probeLog = Paths.root.appendingPathComponent("spawn-probe.log")
            let probeCmd = Privileged.buildBackgroundCommand(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                logPath: probeLog.path,
                workingDirectory: Paths.root.path)
            check("命令含输出重定向", probeCmd.contains(" >> ") && probeCmd.contains("& echo $!"),
                  probeCmd)
            check("命令含工作目录切换", probeCmd.contains("cd '"))
            check("整条命令被花括号包裹后重定向", probeCmd.hasPrefix("{ ") && probeCmd.contains("; } >> "),
                  probeCmd)

            let pump = Process()
            pump.executableURL = URL(fileURLWithPath: "/bin/sh")
            pump.arguments = ["-c", probeCmd]
            let pumpOut = Pipe()
            pump.standardOutput = pumpOut
            pump.standardError = Pipe()
            pump.standardInput = FileHandle.nullDevice

            let t0 = ProcessInfo.processInfo.systemUptime
            try? pump.run()
            let outData = pumpOut.fileHandleForReading.readDataToEndOfFile()
            pump.waitUntilExit()
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000

            // 这是关键断言：如果后台进程没做输出重定向，它会继承管道，
            // 这里会阻塞整整 30 秒而不是立即返回。
            check("后台启动立即返回（重定向生效）", elapsedMs < 3000,
                  String(format: "%.0f ms", elapsedMs))

            let pidText = (String(data: outData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let bgPID = pid_t(pidText) {
                check("回显后台进程 pid", true, "pid=\(bgPID)")
                check("后台进程存活检测", Privileged.processExists(bgPID))

                kill(bgPID, SIGTERM)   // 与 TUN 停止路径同一条信号
                var ticks = 0
                while Privileged.processExists(bgPID) && ticks < 30 {
                    usleep(100_000)
                    ticks += 1
                }
                check("SIGTERM 能终止后台进程", !Privileged.processExists(bgPID),
                      String(format: "%.1fs", Double(ticks) / 10))
            } else {
                check("回显后台进程 pid", false, "输出='\(pidText)'")
            }
            try? FileManager.default.removeItem(at: probeLog)

            // 10. 优雅停止
            let before = ProcessInfo.processInfo.systemUptime
            k.stop()
            let elapsed = ProcessInfo.processInfo.systemUptime - before
            check("SIGTERM 优雅停止", !k.status.isRunning, String(format: "耗时 %.2fs", elapsed))
            check("停止后清理 runtime.json", !FileManager.default.fileExists(atPath: info.path))
            check("停止后清理 socket", !FileManager.default.fileExists(atPath: Paths.root.appendingPathComponent("ctl.sock").path))

            // 11. 日志确实有内容（验证 stdout 重定向正确）
            let log = Kernel.tailLog(lines: 200)
            check("内核日志非空", log.count > 50 && !log.contains("还没有日志"), "\(log.count) 字符")

            print("───────────────────────────────────────")
            print(failures == 0 ? "全部通过" : "\(failures) 项失败")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }
}
