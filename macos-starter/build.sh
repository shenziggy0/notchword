#!/bin/bash
# 构建并打包成可双击运行的 .app（Universal: arm64 + x86_64）
set -euo pipefail

cd "$(dirname "$0")"

APP="${EW_APP_OUTPUT:-build/Englishwords.app}"
[[ "$APP" =~ ^build/[A-Za-z0-9._-]+\.app$ ]] || {
    echo "输出路径必须是 build 下的应用包" >&2
    exit 1
}
DESTINATION="$APP"
BUNDLE="Englishwords_Englishwords.bundle"
SCRATCH=".build/packaged"
if [ "${EW_ENABLE_SPARKLE:-0}" = 1 ]; then
    bash scripts/fetch_sparkle.sh
    SCRATCH=".build/packaged-sparkle"
fi
SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64 --disable-sandbox --scratch-path "$SCRATCH")

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

echo "==> 打包 $DESTINATION"
mkdir -p build
STAGING="$(mktemp -d "build/.package.XXXXXX")"
trap 'if [[ -d "$STAGING" ]]; then find "$STAGING" -depth -delete; fi' EXIT
APP="$STAGING/${DESTINATION##*/}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Englishwords" "$APP/Contents/MacOS/Englishwords"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$BIN/$BUNDLE" "$APP/Contents/Resources/"

PLIST="$APP/Contents/Info.plist"
IDENTITY="${EW_SIGN_IDENTITY:--}"
PLISTBUDDY=/usr/libexec/PlistBuddy
if [ -n "${EW_BUILD_VERSION:-}" ]; then
    "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $EW_BUILD_VERSION" "$PLIST"
fi
if [ -n "${EW_BUILD_NUMBER:-}" ]; then
    "$PLISTBUDDY" -c "Set :CFBundleVersion $EW_BUILD_NUMBER" "$PLIST"
fi
if [ "${EW_ENABLE_SPARKLE:-0}" = 1 ]; then
    FRAMEWORK="scripts/.cache/sparkle-2.9.6/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
    cp "scripts/.cache/sparkle-2.9.6/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
    if [ -n "${EW_SU_FEED_URL:-}" ] || [ -n "${EW_SU_PUBLIC_ED_KEY:-}" ]; then
        case "${EW_SU_FEED_URL:-}" in
            https://*) ;;
            *) echo "Sparkle 更新地址须为 HTTPS" >&2; exit 1 ;;
        esac
        if ! [[ "${EW_SU_PUBLIC_ED_KEY:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
            echo "Sparkle 公钥必须是 32 字节 EdDSA 公钥的 Base64" >&2
            exit 1
        fi
        "$PLISTBUDDY" -c "Add :SUFeedURL string $EW_SU_FEED_URL" "$PLIST"
        "$PLISTBUDDY" -c "Add :SUPublicEDKey string $EW_SU_PUBLIC_ED_KEY" "$PLIST"
    fi
    while IFS= read -r -d '' component; do
        codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,identifier "$component"
    done < <(find "$APP/Contents/Frameworks" -depth \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -type d -print0)
    otool -L "$APP/Contents/MacOS/Englishwords" | awk '/@rpath\/Sparkle.framework/ { found = 1 } END { exit !found }'
fi

# 开发构建默认使用临时身份。发布脚本要求稳定签名。
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

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
    OK*unbelievable*PARTS*) ;;
    *) echo "随包词库自检失败" >&2; exit 1 ;;
esac

if ! find "$APP/Contents/Resources" -name subtitle.js -type f | awk 'NF { found = 1 } END { exit !found }'; then
    echo "缺少字幕资源" >&2
    exit 1
fi

if [ -e "$DESTINATION" ]; then
    mv "$DESTINATION" "$STAGING/previous.app"
fi
if ! mv "$APP" "$DESTINATION"; then
    if [ -d "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$DESTINATION"; fi
    exit 1
fi
APP="$DESTINATION"

echo "==> 完成"
echo "    双击打开：$(pwd)/$APP"
echo "    或命令行：open \"$APP\""
