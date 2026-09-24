import Foundation
import AppKit
import Darwin
import HelperProtocol

/// 取进程的属主用户名。用来确认提权内核真的是 root 跑的。
func processOwner(_ pid: pid_t) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "user=", "-p", "\(pid)"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "?" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "?")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

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

            // 9b. 特权助手
            check("助手协议版本一致", Helper.protocolVersion == 2, "v\(Helper.protocolVersion)")
            check("助手二进制已打包", HelperInstaller.bundledHelperPath() != nil,
                  HelperInstaller.bundledHelperPath()?.path ?? "未找到（开发时用 swift run 属正常）")
            check("助手安装状态可查", HelperInstaller.isInstalled == FileManager.default.isExecutableFile(atPath: Helper.installedPath),
                  HelperInstaller.isInstalled ? "已安装" : "未安装")
            if HelperInstaller.isInstalled {
                let running = HelperInstaller.isRunning
                check("助手可应答 ping", running, running ? "正常运行" : "未运行（重启后由 launchd 拉起）")
                if running {
                    // Gatekeeper 回归检查。
                    // 带 com.apple.quarantine 的二进制以 root 执行会被 SIGKILL（rc=137），
                    // 且**不产生任何日志** —— 症状是“助手报启动成功但内核秒退”，
                    // 肉眼基本查不出来，所以必须自动盯着。
                    let staged = "\(Helper.socketDirectory)/mihomo"
                    if FileManager.default.fileExists(atPath: staged) {
                        check("提权内核已去隔离属性", !HelperInstaller.needsQuarantineClear(staged),
                              HelperInstaller.needsQuarantineClear(staged)
                              ? "带 com.apple.quarantine → root 执行会被 SIGKILL" : "干净")
                    }

                    var req = Helper.Request(cmd: .kernelStatus)
                    req.protocolVersion = Helper.protocolVersion
                    if let resp = try? HelperSocket.call(req) {
                        check("助手可查询内核状态", true, resp.running == true ? "内核在跑" : "内核未跑")
                    } else {
                        check("助手可查询内核状态", false)
                    }

                    // 真正验证提权路径：让助手以 root 启动内核
                    print("  … 通过助手以 root 启动内核")
                    let helperKernel = Kernel()
                    await helperKernel.start(config: config,
                                             binary: kernel,
                                             dataDir: Paths.dataDir,
                                             uiDir: ui,
                                             privileged: true)
                    if helperKernel.status.isRunning {
                        check("助手以 root 启动内核", true, ":\(helperKernel.port)")
                        check("内核标记为提权", helperKernel.isPrivileged)

                        // 关键：确认内核进程真的是 root，而不是默默回退成普通用户
                        if let pid = helperKernel.runningPID {
                            let owner = processOwner(pid)
                            check("内核进程确实以 root 运行", owner == "root", "owner=\(owner)")
                        }
                        if let url = helperKernel.endpoint {
                            let ctl = CtlClient(base: url, secret: helperKernel.secret)
                            let v = try? await ctl.version()
                            check("提权内核 API 可达", v != nil, v?.version ?? "无响应")
                        }
                        helperKernel.stop()
                        check("提权内核已停止", !helperKernel.status.isRunning)
                    } else {
                        check("助手以 root 启动内核", false, helperKernel.lastError ?? "未知")
                    }
                }
            } else {
                print("  ℹ️  助手未安装，跳过提权路径测试（可在应用设置里安装）")
            }

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

            // 9c. 设置解码的向后兼容性。
            //     Swift 合成的 Codable 对缺失的非可选字段会直接失败 —— 那意味着
            //     以后每加一个设置项，老用户的 settings.json 就会全部回退成默认值。
            //     这里拿一份“缺少新字段的旧配置”验证手写解码确实能兼容。
            let legacyJSON = #"{"subscriptionURL":"https://example.com/sub","mixedPort":1234}"#
            if let data = legacyJSON.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
                check("旧版 settings.json 可解码", true,
                      "订阅保留=\(decoded.subscriptionURL.contains("example.com"))"
                      + " 端口=\(decoded.mixedPort)"
                      + " 新字段默认=\(decoded.showInDock)")
                check("旧配置的已有值未被覆盖",
                      decoded.subscriptionURL == "https://example.com/sub" && decoded.mixedPort == 1234)
            } else {
                check("旧版 settings.json 可解码", false, "解析失败，老用户设置会丢失")
            }

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
