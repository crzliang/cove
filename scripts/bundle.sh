#!/usr/bin/env bash
# 组装 MihomoBar.app
#
# 刻意不用 Xcode 工程：只要装了 Command Line Tools 就能构建和打包，
# 产物结构与 Xcode 生成的一致，将来想迁到 Xcode 也不用改代码。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="MihomoBar"
BUNDLE_ID="local.mihomobar"
VERSION="${VERSION:-0.1.0}"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

echo "==> 编译 release"
swift build -c release

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# 特权助手单独一个二进制，由用户从设置里手动安装到 /Library/PrivilegedHelperTools。
# 它不会随 app 自动获得 root，必须显式安装（那一步弹一次授权）。
if [ -x ".build/release/MihomoBarHelper" ]; then
  cp ".build/release/MihomoBarHelper" "$APP/Contents/MacOS/MihomoBarHelper"
else
  echo "!! 缺少 MihomoBarHelper，TUN 模式将不可用" >&2
fi

# 内核与面板作为普通资源随包分发；首次启动时复制到 Application Support 再执行
if [ -x "Resources/mihomo" ]; then
  cp "Resources/mihomo" "$APP/Contents/Resources/mihomo"
else
  echo "!! 缺少 Resources/mihomo，请先运行 scripts/fetch-kernel.sh" >&2
  exit 1
fi
if [ -d "Resources/ui" ]; then
  cp -R "Resources/ui" "$APP/Contents/Resources/ui"
else
  echo "   (未找到 Resources/ui，面板功能将不可用)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- 默认作为常规应用（有 Dock 图标）。
         是否显示 Dock 图标由运行时 setActivationPolicy 控制，
         用户可在设置里关掉，退化为纯菜单栏应用。 -->
    <key>LSUIElement</key>               <false/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
</dict>
</plist>
PLIST

echo "==> 签名"
IDENTITY="${SIGN_IDENTITY:--}"
# 先签内层再签外层（code signing 的顺序不能反）
if [ -x "$APP/Contents/MacOS/MihomoBarHelper" ]; then
  codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/MihomoBarHelper" 2>&1 | grep -v "replacing existing" || true
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/$APP_NAME" 2>&1 | grep -v "replacing existing" || true
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
else
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo
echo "==> 完成"
du -sh "$APP" | awk '{print "  体积: " $1}'
echo "  路径: $APP"
echo
echo "运行:  open '$APP'"
echo "自检:  MIHOMOBAR_RESOURCES='$APP/Contents/Resources' '$APP/Contents/MacOS/$APP_NAME' --selftest"
