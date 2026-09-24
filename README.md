# MihomoBar

macOS 菜单栏 mihomo 代理客户端。原生 Swift + AppKit，**无 webview**。

```
GUI 本体      ~1.3 MB（release）
含内核+面板   ~34 MB
内存 footprint 低（无 WebKit 进程）
```

---

## 设计要点

### 0. 形态：独立主窗口 + 菜单栏并存

启动时打开主窗口（`520×720`，可拉伸），同时保留菜单栏图标用于快速开关。
Dock 图标可在设置里关掉，关掉后窗口收起，退化成纯菜单栏应用。

窗口位置用 `setFrameAutosaveName` 记忆，但恢复前会做一次**可见性校验** ——
显示器拔插或分辨率变化后，旧坐标可能落在屏幕外，那样窗口看起来就像“根本没启动”。

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
| **带 quarantine 的内核被 root 执行时被 SIGKILL，且零输出** | 安装/复制时清除 `com.apple.quarantine`，并在自检里盯着 |
| **`NSWindow.center()` 在应用未激活时会把窗口放到屏幕外** | 基于 `visibleFrame` 自行定位 + 可见性校验 |

### 5. 复杂 UI 交给 MetaCubeXD

节点列表、规则编辑、连接列表、流量曲线在浏览器面板里（点「面板」）。
菜单栏只放每天真正会用的：启停、系统代理、模式、策略组快切、订阅状态、日志。

面板是 **响应式 PWA** —— 手机连同一个地址（需开 `allow-lan`）就是第二个客户端。
多客户端能力由内核提供，不需要自己实现。

### 6. 特权操作交给常驻 root 助手，只授权一次

**整个应用只有一次授权弹框**，发生在安装助手时。之后 TUN 开关、系统代理
全部走 unix socket 到 root 助手，不再有任何提示 —— 指纹和密码都不需要。

```
MihomoBar (用户)
     │  unix socket  /var/run/local.mihomobar/helper.sock  (root:admin 0660)
     ▼
MihomoBarHelper (root, launchd 常驻)          ← launchd 拉起，KeepAlive
     ├── spawn mihomo 并持有 Process 句柄       ← 不再需要 osascript
     └── networksetup 开关系统代理
```

安装只需要一次提权 shell：

```
install -m 755 -o root -g wheel  <app>/Contents/MacOS/MihomoBarHelper \
                                  /Library/PrivilegedHelperTools/local.mihomobar.helper
install -m 644 -o root -g wheel  local.mihomobar.helper.plist \
                                 /Library/LaunchDaemons/
launchctl bootstrap system /Library/LaunchDaemons/local.mihomobar.helper.plist
```

**为什么不用 `SMAppService.daemon`**：它要求应用带 Apple 开发者证书签名
（需要 Team Identifier）。实测自签名证书返回
`SMAppServiceErrorDomain Code=1 "Operation not permitted"`。传统路径效果一样且不挑签名。

安全边界：

* socket 是 `root:admin 0660` —— 只有 root 与管理员组成员能连
* 助手再用 `getpeereid()` 做第二道校验
* 内核二进制另外装一份到 root 专属目录。**不能直接执行 Application Support
  里的那份** —— 那个目录用户可写，任何能写它的进程都能换掉内核从而拿到 root 执行
* 提权模式下会检查配置里有没有 `post-up` / `post-down` —— 内核会以 root
  执行它们，存在就直接拒绝启动并提示

助手自身也踩过两个坑（都在代码注释里）：

1. **socket 组必须是 admin 而不是默认的 daemon**。launchd 拉起的进程 gid 是
   daemon，普通用户不在该组里，症状是「助手在跑但连不上」
2. `launchctl bootstrap` 到 socket 可连有时要几秒，安装后的探测窗口不能太短

### 7. 开机自启用 SMAppService

macOS 13+ 的 `SMAppService.mainApp`，注册 app 自身，不需要写 plist、不需要 helper。

⚠️ **需要把 app 放到 `/Applications`**，系统才能可靠跟踪它。
从 `build/` 直接运行会显示 `.notFound`，UI 上会提示。

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

40+ 项，覆盖：资源定位 → 生成配置 → 分配端口 → `-t` 预检 → 启动 →
`/version` `/configs` `/proxies` `/providers/proxies` → 切模式 → 重载 →
面板可达 → `runtime.json` → 提权命令构造 → SIGTERM 优雅停止 → 清理 socket →
日志非空。

助手已安装时还会做真正的提权端到端验证：让助手以 root 启动内核，
用 `ps -o user=` **确认进程属主真的是 root**，再验证 API 可达并干净停止。

自检已实际抓出四个 bug：资源目录被整个当成内核拷贝、提权重定向写法导致阻塞 30 秒、
助手 socket 组不对导致连不上、以及提权内核缺隔离属性检查。

```bash
# 助手相关（都需要在 .app 内运行）
MihomoBar --install-helper     # 安装（弹一次授权）
MihomoBar --uninstall-helper
MihomoBar --helper-status
```

---

## 权限模型

| 操作 | 需要 root | 授权次数 |
|---|---|---|
| 启动内核（代理端口模式） | 否 | — |
| 打开浏览器面板 | 否 | — |
| **安装特权助手** | 是 | **一次**（可用触控 ID） |
| **系统代理开关** | 是 | 0（走助手） |
| **TUN 模式** | 是 | 0（走助手） |

**没装助手时**会降级到 `osascript ... with administrator privileges`，
每次操作弹一次框（支持触控 ID）。装了助手就彻底告别弹框。

---

## 开机自启

设置面板里的「开机自启」开关，底层是 `SMAppService.mainApp`。
**先把 app 放到 `/Applications`** 再打开这个开关：

```bash
cp -R build/MihomoBar.app /Applications/
open /Applications/MihomoBar.app
```

---

## 目录结构

```
Sources/MihomoBar/
  App.swift            入口（@main），含 --selftest 分支
  AppDelegate.swift    NSStatusItem + NSPopover + 右键菜单 + 退出收尾
  AppModel.swift       共享状态（刻意不用 @State）
  Kernel.swift         进程生命周期 / 提权启动 / 端口 / 预检 / 日志
  CtlClient.swift      external-controller REST 客户端
  Privileged.swift     osascript 提权 + networksetup + 异步启动机制
  LaunchAtLogin.swift  SMAppService 开机自启
  ConfigWriter.swift   生成配置（永不写用户配置）
  Bundled.swift        资源定位与内核副本
  SelfTest.swift       headless 自检（33 项）
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

- [ ] 订阅定时刷新状态显示（内核已在刷，UI 只显示 `updatedAt`）
- [ ] `SMAppService` helper 替代 osascript，免去反复授权
- [ ] 流量速率显示（`/traffic` 是流式接口）
- [ ] 用 `NSStatusItem.button.image` 叠加延迟数字
- [ ] 图标资源（现在用 SF Symbols）
- [ ] 内核版本更新（替换 `~/Library/Application Support/MihomoBar/mihomo` 即可）
