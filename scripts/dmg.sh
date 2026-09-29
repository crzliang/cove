#!/usr/bin/env bash
# 先打 Cove.app，再做成可拖进「应用程序」的 dmg。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
APP_NAME="Cove"
APP="$ROOT/build/$APP_NAME.app"
# CI 可设 DMG_SUFFIX=-arm64，本地默认不带后缀。
DMG="$ROOT/build/${APP_NAME}-${VERSION}${DMG_SUFFIX:-}.dmg"

bash "$ROOT/scripts/bundle.sh"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "==> 制作 $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

echo
echo "==> 完成"
du -sh "$DMG" | awk '{print "  体积: " $1}'
echo "  路径: $DMG"
