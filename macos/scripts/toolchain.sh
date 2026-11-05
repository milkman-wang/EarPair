# 被其他脚本 source：选一个能用的 Swift 工具链。
# 如果没有指定 DEVELOPER_DIR，而当前选中的是"命令行工具"（它的 SwiftPM 有时和 SDK 版本对不上），
# 就改用 /Applications 里的 Xcode。不会修改系统设置（xcode-select）。
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  for xcode in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$xcode/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$xcode/Contents/Developer"
      echo "使用 $xcode 的工具链"
      break
    fi
  done
fi
