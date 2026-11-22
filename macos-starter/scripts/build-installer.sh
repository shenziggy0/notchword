#!/bin/bash
set -euo pipefail

APP="${1:?用法：bash scripts/build-installer.sh 应用.app 输出.pkg}"
PKG="${2:?缺少安装包输出路径}"
SCRIPTS="$(dirname "$0")"
PLISTBUDDY=/usr/libexec/PlistBuddy
INFO="$APP/Contents/Info.plist"
BUNDLE_ID="$($PLISTBUDDY -c 'Print :CFBundleIdentifier' "$INFO")"
BUILD="$($PLISTBUDDY -c 'Print :CFBundleVersion' "$INFO")"
[[ "$BUNDLE_ID" = io.github.shenziggy0.notchword ]] || { echo "应用标识不匹配：$BUNDLE_ID" >&2; exit 1; }

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/englishwords-installer.XXXXXX")"
trap 'find "$STAGING" -depth -delete' EXIT
mkdir -p "$STAGING/payload" "$STAGING/scripts"
ditto "$APP" "$STAGING/payload/Englishwords.app"
install -m 0755 "$SCRIPTS/pkg-postinstall.sh" "$STAGING/scripts/postinstall"

COMPONENTS="$STAGING/components.plist"
# 明确指定位置和覆盖规则，不依赖不同 macOS 版本生成的默认配置。
$PLISTBUDDY -c 'Clear array' -c 'Add :0 dict' \
    -c 'Add :0:RootRelativeBundlePath string Englishwords.app' \
    -c 'Add :0:BundleIsRelocatable bool false' \
    -c 'Add :0:BundleIsVersionChecked bool false' \
    -c 'Add :0:BundleHasStrictIdentifier bool true' \
    -c 'Add :0:BundleOverwriteAction string upgrade' "$COMPONENTS"

pkgbuild --root "$STAGING/payload" --component-plist "$COMPONENTS" \
    --scripts "$STAGING/scripts" --install-location /Applications \
    --identifier "$BUNDLE_ID.installer" --version "$BUILD" "$PKG"
