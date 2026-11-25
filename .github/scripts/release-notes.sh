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

if ! notes="$(awk -v heading="## [$version]" '
  {
    sub(/\r$/, "")
    if (/^##[[:blank:]]+/) {
      tail = substr($0, length(heading) + 1)
      in_section = index($0, heading) == 1 && (tail == "" || tail ~ /^[[:blank:]]/)
      if (in_section) sections++
      next
    }
    if (/^\[[^]]+\]:[[:blank:]]*/) in_section = 0
    if (!in_section) next
    if (lines == 0 && /^[[:space:]]*$/) next
    body[++lines] = $0
    if (/[^[:space:]]/ && !/^[[:blank:]]*#+[[:blank:]]+/) has_content = 1
  }
  END {
    if (sections != 1 || !has_content) exit 1
    while (lines > 0 && body[lines] ~ /^[[:space:]]*$/) lines--
    for (i = 1; i <= lines; i++) print body[i]
  }
' <<< "$changelog")"; then
  echo "版本 $version 的提交 $commit 必须包含唯一且有正文的「## [$version]」章节。" >&2
  exit 1
fi
printf '%s\n' "$notes"
