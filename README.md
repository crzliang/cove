# MihomoBar

macOS 菜单栏 mihomo 代理客户端。原生 Swift + AppKit，**无 webview**。

```
GUI 本体      ~1.3 MB（release）
含内核+面板   ~34 MB
内存 footprint 低（无 WebKit 进程）
```

---

## 设计要点

### 1. 内核是独立子进程，不是链接进来的库

mihomo 采用 **GPL-3.0**。把它 `import` 进本程序会让整个应用继承 GPL-3.0；
以子进程方式 spawn 则属于"聚合"，许可上互不影响（Clash Verge / ClashX 同样做法）。

代价是要自己管进程生命周期 —— 见下面第 4 点。

### 2. 绝不改写用户配置

用户配置以只读方式经 `-f` 传给内核。应用自己需要的东西
（控制器端口、secret、面板路径）**全部用命令行覆盖**：

```
mihomo -d <datadir> -f <用户配置> \
       -ext-ctl 127.0.0.1:<随机空闲端口> \
       -ext-ctl-unix <datadir>/ctl.sock \
       -ext-ui <datadir>/ui \
       -secret <随机>
```

这条路径经过实测：用户 `config.yaml` 的 md5 完全不变，但 UI、API、端口全部生效。

### 3. 控制器用随机空闲端口，不是 9090

9090 会和 ClashX / Clash Verge / 其他 mihomo 实例抢端口。
启动时 `bind(127.0.0.1:0)` 让系统分配，实际端口写在
`~/Library/Application Support/MihomoBar/runtime.json`。

### 4. 实测踩过的坑（都在代码里处理了）

| 现象 | 处理 |
|---|---|
| mihomo 日志走 **stdout** 而非 stderr | stdout 和 stderr 都重定向到日志文件 |
| 内核被 kill 后 unix socket 文件残留 | 启动前 **和** 停止后都 unlink |
| `Child.kill()` 是 SIGKILL，TUN 模式留残路由 | `Process.terminate()`（SIGTERM）→ 等 3s → SIGKILL 兜底 |
| 配置错误时内核静默退出，只留空日志 | 启动前跑 `mihomo -t` 预检 |
| `sleep N` 等内核就绪不可靠 | 轮询 `/version` 直到 200，最多 15s |
| 内核崩溃后 UI 仍显示"运行中" | `terminationHandler` 感知退出并更新状态 |

### 5. 复杂 UI 交给 MetaCubeXD

节点列表、规则编辑、连接列表、流量曲线在浏览器面板里（点「面板」）。
菜单栏只放每天真正会用的：启停、系统代理、模式、策略组快切、日志。

面板是 **响应式 PWA** —— 手机连同一个地址（需开 `allow-lan`）就是第二个客户端。
多客户端能力由内核提供，不需要自己实现。

---

## 构建

需要 macOS 13+ 和 Command Line Tools。

```bash
# 1. 获取内核与面板
./scripts/fetch-kernel.sh

# 2. 开发运行
swift build && ./.build/debug/MihomoBar

# 3. 打包成 .app
./scripts/bundle.sh
open build/MihomoBar.app
```

### 关于 Xcode

本项目**刻意只依赖 Command Line Tools**，你现在就能构建。

原因：SwiftUI 的宏插件（`SwiftUIMacros` / `PreviewsMacros`）只随 Xcode 分发，
仅装 CLT 时 `@State` 和 `#Preview` 无法编译。因此本项目所有瞬态 UI 状态
都放在共享的 `AppModel`（`@StateObject` + `ObservableObject`），
这在两种环境下行为完全一致。

装了 Xcode 之后可以逐步用回 `@State`，去掉 `#Preview` 的缺失也只是少了预览功能。

---

## 自检

无需点界面即可验证整条链路：

```bash
./.build/debug/MihomoBar --selftest
```

会依次检查：定位内核 → 生成配置 → 分配端口 → `-t` 预检 → 启动 →
`/version` `/configs` `/proxies` → 切模式 → 重载 → 面板可达 →
`runtime.json` → SIGTERM 优雅停止 → 清理 socket → 日志非空。

不做任何系统级改动。

---

## 权限模型

| 操作 | 是否需要 root |
|---|---|
| 启动内核（代理端口模式） | 否 |
| 打开浏览器面板 | 否 |
| **系统代理开关** | **是**（`networksetup -setwebproxy`） |
| **TUN 模式** | **是** |

系统代理通过 `osascript ... with administrator privileges` 一次性授权，
零签名成本、立刻可用；缺点是重启后需重新授权一次。

将来要免去反复授权，可换成 `SMAppService` 注册 LaunchDaemon helper
（Clash Verge 的做法）。`Privileged.swift` 的接口已为此预留，可平滑替换。

TUN 模式目前**只写入配置**，内核仍以当前用户身份运行，因此不会生效。
要真正启用需要把内核也提权启动。

---

## 目录结构

```
Sources/MihomoBar/
  App.swift            入口（@main）
  AppDelegate.swift    NSStatusItem + NSPopover + 右键菜单
  AppModel.swift       共享状态（刻意不用 @State）
  Kernel.swift         进程生命周期 / 端口 / 预检 / 日志
  CtlClient.swift      external-controller REST 客户端
  Privileged.swift     osascript 提权 + networksetup
  ConfigWriter.swift   生成配置（永不写用户配置）
  Bundled.swift        资源定位与内核副本
  SelfTest.swift       headless 自检
  Views/RootView.swift 弹出面板

Resources/             mihomo + ui/（gitignore，用脚本获取）
scripts/fetch-kernel.sh
scripts/bundle.sh
```

运行时数据在 `~/Library/Application Support/MihomoBar/`：

```
mihomo         内核副本（可执行，将来换内核只需替换它）
generated.yaml 应用生成的配置
data/          内核工作目录（cache.db / mmdb / providers/）
mihomo.log     内核 stdout+stderr
runtime.json   当前端口与 secret
settings.json  应用设置
```

---

## 待办

- [ ] 开机自启（`SMAppService.mainApp.register()`）
- [ ] 订阅更新后自动 `PUT /configs` 重载
- [ ] TUN 模式提权启动内核
- [ ] `SMAppService` helper 替代 osascript
- [ ] 流量速率显示（`/traffic` 是流式接口）
- [ ] 用 `NSStatusItem.button.image` 叠加延迟数字
- [ ] 图标资源
