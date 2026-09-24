#!/usr/bin/env bash
# 拉取 mihomo 内核与 MetaCubeXD 面板到 Resources/
#
# 内核是独立进程 spawn 的，不是链接进本程序的库 ——
# 这样本应用不必继承 mihomo 的 GPL-3.0 许可。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="$ROOT/Resources"
mkdir -p "$RES"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) MH_ASSET="mihomo-darwin-arm64-" ;;
  x86_64) MH_ASSET="mihomo-darwin-amd64-" ;;
  *) echo "不支持的架构: $ARCH" >&2; exit 1 ;;
esac

# ---------- mihomo ----------
if [ -x "$RES/mihomo" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "内核已存在：$("$RES/mihomo" -v | head -1)"
  echo "（想强制重下请用 FORCE=1 $0）"
else
  echo "查询 mihomo 最新版本…"
  TAG=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
  URL="https://github.com/MetaCubeX/mihomo/releases/download/${TAG}/${MH_ASSET}${TAG}.gz"
  echo "下载 $TAG ($ARCH)…"
  curl -fL --progress-bar "$URL" -o "$RES/mihomo.gz"
  gunzip -f "$RES/mihomo.gz"
  chmod 755 "$RES/mihomo"
  echo "完成：$("$RES/mihomo" -v | head -1)"
fi

# ---------- MetaCubeXD ----------
if [ -d "$RES/ui" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "面板已存在：$RES/ui"
else
  echo "查询 MetaCubeXD 最新版本…"
  TAG=$(curl -fsSL https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
  echo "下载 MetaCubeXD $TAG…"
  rm -rf "$RES/ui" "$RES/ui-dist"
  curl -fL --progress-bar \
    "https://github.com/MetaCubeX/metacubexd/archive/refs/tags/${TAG}.tar.gz" \
    -o "$RES/ui.tar.gz"
  tar -xzf "$RES/ui.tar.gz" -C "$RES"
  mv "$RES/metacubexd-${TAG#v}" "$RES/ui-dist"
  # 仓库根就是可直接托管的静态站点
  rm -f "$RES/ui.tar.gz"
  echo "注意：MetaCubeXD 源码需要构建才能得到静态产物。"
  echo "如已有构建好的 dist，请放到 $RES/ui"
fi

echo
echo "Resources/ 内容："
ls -lh "$RES"
