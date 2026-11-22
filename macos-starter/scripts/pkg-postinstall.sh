#!/bin/bash
set -euo pipefail

# 安装器以 root 运行，只记录事件，不替任何用户触碰系统隐私授权。
STATE_DIR="${3:?缺少目标卷}/private/var/db"
TEMPORARY="$(/usr/bin/mktemp "$STATE_DIR/.notchword-install-id.XXXXXX")"
trap '/bin/rm -f "$TEMPORARY"' EXIT
/usr/bin/uuidgen > "$TEMPORARY"
/bin/chmod 0644 "$TEMPORARY"
/bin/mv -f "$TEMPORARY" "$STATE_DIR/io.github.shenziggy0.notchword.install-id"
