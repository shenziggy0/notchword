#!/bin/bash
# 构建并打包成可双击运行的 .app（Universal: arm64 + x86_64）
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Englishwords.app"
BUNDLE="Englishwords_Englishwords.bundle"
SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64 --disable-sandbox)

echo "==> 编译（arm64 + x86_64）"
swift build "${SWIFT_FLAGS[@]}"

BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
if [ ! -x "$BIN/Englishwords" ]; then
    echo "找不到编译产物：$BIN/Englishwords" >&2
    exit 1
fi

echo "==> 检查资源包"
if [ ! -d "$BIN/$BUNDLE" ]; then
    echo "缺少资源包：$BIN/$BUNDLE" >&2
    exit 1
fi

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Englishwords" "$APP/Contents/MacOS/Englishwords"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R "$BIN/$BUNDLE" "$APP/Contents/Resources/"

# 只用于本机运行；正式分发需要 Developer ID 与公证
codesign --force --sign - "$APP/Contents/Resources/$BUNDLE" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (跳过 codesign)"

echo "==> 校验产物"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Englishwords")"
echo "    架构：$ARCHS"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "产物不是 Universal：$ARCHS" >&2; exit 1 ;;
esac

# 清掉开发期环境变量，验证随包资源真的能读
CHECK="$(env -u EW_DICT -u EW_PARTS "$APP/Contents/MacOS/Englishwords" --check-word unbelievable)"
echo "$CHECK" | sed 's/^/    /'
case "$CHECK" in
    OK*unbelievable*) ;;
    *) echo "随包词库自检失败" >&2; exit 1 ;;
esac

echo "==> 完成"
echo "    双击打开：$(pwd)/$APP"
echo "    或命令行：open \"$APP\""
