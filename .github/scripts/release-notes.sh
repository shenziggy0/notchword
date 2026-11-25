#!/bin/bash
set -euo pipefail

version="${1:-}"
ref="${2:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || -z "$ref" ]]; then
  echo "用法：bash .github/scripts/release-notes.sh <版本号> <Git 引用>，例如 0.5.4 HEAD" >&2
  exit 1
fi

if ! commit="$(git rev-parse --verify --end-of-options "${ref}^{commit}" 2>/dev/null)"; then
  echo "版本 $version 无法解析 Git 引用 $ref。" >&2
  exit 1
fi
if ! changelog="$(git show "$commit:CHANGELOG.md" 2>/dev/null)"; then
  echo "版本 $version 的提交 $commit 缺少 CHANGELOG.md。" >&2
  exit 1
fi

if ! notes="$(awk -v version="$version" '
  # 注释只影响结构识别和正文校验，输出仍保留 Markdown 原文。
  function visible_text(line,    result, marker, size, token, rest) {
    while (1) {
      if (in_comment) {
        marker = index(line, "-->")
        if (!marker) return result
        line = substr(line, marker + 3)
        in_comment = 0
      } else {
        if (!match(line, /<!--|`+/)) return result line
        marker = RSTART
        size = RLENGTH
        token = substr(line, marker, size)
        result = result substr(line, 1, marker - 1)
        line = substr(line, marker + size)
        if (token == "<!--") {
          in_comment = 1
        } else {
          # 行内代码中的注释标记是可见文字。
          result = result token
          rest = line
          while (match(rest, /`+/)) {
            if (RLENGTH == size) {
              size = length(line) - length(rest) + RSTART + RLENGTH - 1
              result = result substr(line, 1, size)
              line = substr(line, size + 1)
              break
            }
            rest = substr(rest, RSTART + RLENGTH)
          }
        }
      }
    }
  }

  {
    sub(/\r$/, "")
    line = $0
    sub(/^ ? ? ?/, "", line)
    fence_length = match(line, /^(```+|~~~+)/) ? RLENGTH : 0
    fence_char = substr(line, 1, 1)
    after_fence = substr(line, fence_length + 1)
    version_link = 0

    if (fence != "") {
      if (fence_char == fence && fence_length >= opening_length && after_fence ~ /^[[:blank:]]*$/) {
        fence = ""
        visible = 0
      } else {
        visible = ($0 ~ /[^[:space:]]/)
      }
    } else if (!in_comment && fence_length && (fence_char == "~" || after_fence !~ /`/)) {
      fence = fence_char
      opening_length = fence_length
      visible = 0
    } else {
      was_in_comment = in_comment
      content = visible_text($0)
      if (!was_in_comment && $0 ~ /^ ? ? ?##([[:blank:]]|$)/) {
        title = content
        sub(/^ ? ? ?##[[:blank:]]+/, "", title)
        heading = "[" version "]"
        tail = substr(title, length(heading) + 1)
        in_section = index(title, heading) == 1 && (tail == "" || tail ~ /^[[:blank:]]/)
        if (in_section) sections++
        next
      }
      version_link = (!was_in_comment && line ~ /^\[(Unreleased|[0-9]+\.[0-9]+\.[0-9]+)\]:/)
      visible = (content ~ /[^[:space:]]/ &&
                 content !~ /^[[:blank:]]*#+([[:blank:]]|$)/ &&
                 content !~ /^ ? ? ?\[[^]]+\]:/)
    }

    if (!in_section) next
    if (lines == 0 && /^[[:space:]]*$/) next
    body[++lines] = $0
    footer_link[lines] = version_link
    if (visible) has_content = 1
  }
  END {
    if (sections != 1 || !has_content) exit 1
    # 仅移除文件末尾的版本比较链接，保留章节中的链接定义。
    while (lines > 0 && (body[lines] ~ /^[[:space:]]*$/ || (in_section && footer_link[lines]))) lines--
    for (i = 1; i <= lines; i++) print body[i]
  }
' <<< "$changelog")"; then
  echo "版本 $version 的提交 $commit 必须包含唯一且有正文的「## [$version]」章节。" >&2
  exit 1
fi
printf '%s\n' "$notes"
