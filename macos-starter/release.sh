#!/bin/bash
# Build and sign a DMG and emit an appcast item for review.
set -euo pipefail
cd "$(dirname "$0")"

: "${EW_SIGN_IDENTITY:?需要稳定的代码签名身份}"
: "${EW_SU_FEED_URL:?需要 HTTPS appcast 地址}"
: "${EW_SU_PUBLIC_ED_KEY:?需要 Sparkle EdDSA 公钥}"
: "${EW_RELEASE_DOWNLOAD_URL:?需要 DMG 的最终 HTTPS 下载地址}"
: "${EW_BUILD_VERSION:?需要产品版本，例如 1.0.0}"
: "${EW_BUILD_NUMBER:?需要递增的数字构建号}"

[[ "$EW_SIGN_IDENTITY" != "-" ]] || { echo "发布不能使用临时签名" >&2; exit 1; }
[[ "$EW_RELEASE_DOWNLOAD_URL" == https://* ]] || { echo "下载地址须为 HTTPS" >&2; exit 1; }
[[ "$EW_BUILD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$EW_BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "版本或构建号格式无效" >&2
    exit 1
}

export EW_ENABLE_SPARKLE=1
export EW_APP_OUTPUT="build/Englishwords-release.app"
TOOLS="scripts/.cache/sparkle-2.9.6/bin"
KEY_ACCOUNT="${EW_SPARKLE_KEY_ACCOUNT:-notchword}"
bash scripts/fetch_sparkle.sh
HERE_KEY="$("$TOOLS/generate_keys" --account "$KEY_ACCOUNT" -p)"
[[ "$EW_SU_PUBLIC_ED_KEY" == "$HERE_KEY" ]] || { echo "Sparkle 公钥与钥匙串账号不匹配" >&2; exit 1; }
bash ./build.sh

BASE="Englishwords-$EW_BUILD_VERSION-$EW_BUILD_NUMBER"
DMG="build/$BASE.dmg"
APPCAST="build/$BASE-appcast.xml"
[[ ! -e "$DMG" && ! -e "$APPCAST" ]] || { echo "该版本文件已存在，请使用新构建号" >&2; exit 1; }
STAGING="$(mktemp -d -t englishwords-release)"
ROOT="$STAGING/volume"
mkdir -p "$ROOT"
trap 'if [[ -d "$STAGING" ]]; then find "$STAGING" -depth -delete; fi' EXIT

ditto "$EW_APP_OUTPUT" "$ROOT/Englishwords.app"
ln -s /Applications "$ROOT/Applications"
cp Resources/安装说明.txt "$ROOT/安装说明.txt"
hdiutil create -srcfolder "$ROOT" -volname "Englishwords" -format UDZO "$STAGING/$BASE.dmg" >/dev/null
hdiutil verify "$STAGING/$BASE.dmg" >/dev/null

SIGNATURE="$("$TOOLS/sign_update" --account "$KEY_ACCOUNT" "$STAGING/$BASE.dmg")"
export EW_SIGN_UPDATE_RESULT="$SIGNATURE"
python3 - "$STAGING/$BASE-appcast.xml" <<'PY'
import datetime
import email.utils
import os
import re
import sys
from xml.sax.saxutils import escape, quoteattr

tokens = dict(re.findall(r'([\w:]+)="([^"]+)"', os.environ["EW_SIGN_UPDATE_RESULT"]))
signature, length = tokens.get("sparkle:edSignature"), tokens.get("length")
if not signature or not length or not length.isdigit():
    raise SystemExit("Sparkle 签名工具没有返回签名或长度")
version = os.environ["EW_BUILD_VERSION"]
build = os.environ["EW_BUILD_NUMBER"]
date = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
attributes = {
    "url": os.environ["EW_RELEASE_DOWNLOAD_URL"],
    "sparkle:version": build,
    "sparkle:shortVersionString": version,
    "sparkle:edSignature": signature,
    "length": length,
    "type": "application/octet-stream",
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(f"<item>\n  <title>Englishwords {escape(version)}</title>\n  <pubDate>{date}</pubDate>\n")
    output.write("  <enclosure " + " ".join(f"{name}={quoteattr(value)}" for name, value in attributes.items()) + " />\n</item>\n")
PY

mv "$STAGING/$BASE.dmg" "$DMG"
mv "$STAGING/$BASE-appcast.xml" "$APPCAST"
shasum -a 256 "$DMG" > "$DMG.sha256"
printf '%s\n' "$DMG" "$DMG.sha256" "$APPCAST"
