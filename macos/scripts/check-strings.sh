#!/bin/bash
# 检查界面文字的翻译：代码里要翻译的每个键在各语言的 Localizable.strings 里都有译文、没有多余的译文，
# 查找时都指定了 bundle: .module，占位符对得上（详见 check-strings.swift）。
# 键是编译器在构建时导出的（.stringsdata），所以先构建一遍。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh

# 导出的位置是 Swift Build 构建系统的目录结构
swift build -c release --build-system swiftbuild
swift scripts/check-strings.swift "$(pwd)" .build/out/Intermediates.noindex/EarPair.build/Release
