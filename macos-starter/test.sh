#!/bin/bash
# 运行核心逻辑测试。
#
# 本机只有 Command Line Tools 时，swift-testing 的宏插件不在默认搜索路径里，
# 需要显式加 -plugin-path；装了完整 Xcode 后可以直接 `swift test`。
set -euo pipefail

cd "$(dirname "$0")"

PLUGIN_PATH="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

if [ -d "$PLUGIN_PATH" ]; then
    swift test --disable-sandbox -Xswiftc -plugin-path -Xswiftc "$PLUGIN_PATH" "$@"
else
    swift test "$@"
fi
