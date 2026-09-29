# 构建

需要 macOS 13 或更新版本，以及 Command Line Tools。不需要完整的 Xcode。

## 打包

```bash
./scripts/fetch-kernel.sh   # 下载当前架构的 mihomo，以及 MetaCubeXD 面板
./scripts/bundle.sh         # 产出 build/Cove.app
open build/Cove.app
```

`fetch-kernel.sh` 发现 `Resources/mihomo` 已存在时会跳过下载。要重下：

```bash
FORCE=1 ./scripts/fetch-kernel.sh
```

内核和面板在 `.gitignore` 里，不进仓库。

建议放到「应用程序」后再开开机自启，否则系统可能跟踪不到应用：

```bash
cp -R build/Cove.app /Applications/
open /Applications/Cove.app
```

## 开发运行

```bash
swift build
./.build/debug/Cove
```

界面状态集中在 `AppModel` 里，不使用 `@State`。`@State` 依赖只随 Xcode 分发的宏插件，仅安装 Command Line Tools 时无法编译。

## 自检

不打开窗口即可跑通资源定位、生成配置、启动内核和 API：

```bash
./.build/debug/Cove --selftest
```

打包后的应用：

```bash
COVE_RESOURCES='build/Cove.app/Contents/Resources' \
  build/Cove.app/Contents/MacOS/Cove --selftest
```

其它检查：

```bash
Cove --render-panes [目录]   # 各页面离屏渲染成 PNG
Cove --dump-menu             # 打印菜单栏结构
Cove --dump-menu running     # 先启动内核再打印菜单
Cove --install-helper        # 安装特权助手（会弹授权框）
Cove --uninstall-helper
Cove --helper-status
```

助手相关命令要在 `.app` 里运行，才能找到随包的 `CoveHelper`。

## 运行时目录

`~/Library/Application Support/Cove/`

| 文件 | 内容 |
|---|---|
| `settings.json` | 应用设置与订阅列表 |
| `generated.yaml` | 根据订阅生成的配置 |
| `providers/` | 下载下来的订阅节点 |
| `runtime.json` | 本次运行的控制器端口与密钥 |
| `mihomo.log` | 内核日志 |
| `data/` | 内核工作目录（缓存、地理数据） |

控制器端口在启动时随机分配，避免和其它 mihomo 客户端抢 `9090`。
