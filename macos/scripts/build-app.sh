#!/bin/bash
# 构建菜单栏 App：macos/build/EarPair.app
#
# 可选环境变量：
#   SIGN_IDENTITY  代码签名身份（默认 "-"，即本机临时签名）。有 Apple 开发者证书时建议填上，
#                  macOS 的"本地网络"权限按签名识别 App，临时签名每次重新构建都可能要重新授权。
#   DEVELOPER_DIR  指定 Xcode。不填时，如果当前选中的是命令行工具，会自动改用 /Applications 里的 Xcode。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh

swift build -c release --product EarPair
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/EarPair.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM 链接时把 SDK 版本写成了最低系统版本，系统看到旧 SDK 就按兼容模式画界面（没有 Liquid Glass）。
# 这里改回实际编译用的 SDK 版本。旧系统只看最低版本，不受影响。
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/EarPair" "$BIN_DIR/EarPair"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "完成：$(pwd)/$APP"
echo "运行：open \"$(pwd)/$APP\""
