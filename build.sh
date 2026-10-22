#!/bin/bash
# 编译 LidNoSleep.app（无需 Xcode 工程）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LidNoSleep"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MIN_MACOS="13.0"

rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码"
swiftc \
    -O \
    -swift-version 5 \
    -target "arm64-apple-macos$MIN_MACOS" \
    -framework AppKit \
    -framework IOKit \
    -framework CoreGraphics \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    Sources/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 本地签名（ad-hoc）"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "    签名失败，忽略（本机运行不受影响）"

echo "==> 完成：$(pwd)/$APP"
