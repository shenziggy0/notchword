#!/bin/bash
# Prepare the pinned official binary target and matching release tools.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=2.9.6
SHA=8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606
CACHE="scripts/.cache/sparkle-$VERSION"
ARCHIVE="$CACHE/Sparkle-for-Swift-Package-Manager.zip"
mkdir -p "$CACHE"

if [ ! -f "$ARCHIVE" ]; then
    curl --fail --silent --show-error --location --connect-timeout 15 --max-time 180 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-for-Swift-Package-Manager.zip" \
        -o "$ARCHIVE.part"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA" ]; then
    echo "Sparkle 下载校验失败：$ARCHIVE" >&2
    exit 1
fi
if [ ! -d "$CACHE/Sparkle.xcframework" ] || [ ! -x "$CACHE/bin/sign_update" ]; then
    ditto -x -k "$ARCHIVE" "$CACHE"
fi
