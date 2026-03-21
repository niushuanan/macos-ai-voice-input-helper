#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "缺少 rg（ripgrep），请先安装后再执行密钥扫描。"
  exit 2
fi

if [[ -z "$(git ls-files -co --exclude-standard)" ]]; then
  echo "未发现可扫描文件。"
  exit 0
fi

PATTERN_API_KEY='sk-[A-Za-z0-9]{20,}'
PATTERN_BEARER='Bearer[[:space:]]+[A-Za-z0-9._-]{20,}'
PATTERN_ASSIGN='(?i)(api[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9._-]{20,}["'"'"']'

RAW_MATCHES="$(
  git ls-files -co --exclude-standard -z \
    | xargs -0 rg \
      --pcre2 \
      --line-number \
      --no-heading \
      --color=never \
      --glob '!.git/*' \
      --glob '!DerivedData/*' \
      --glob '!build/*' \
      --glob '!*.xcresult/*' \
      --glob '!scripts/secret-scan.sh' \
      -e "$PATTERN_API_KEY" \
      -e "$PATTERN_BEARER" \
      -e "$PATTERN_ASSIGN" || true
)"

FILTERED_MATCHES="$(printf "%s\n" "$RAW_MATCHES" | rg -v "secret-scan:ignore" || true)"

if [[ -n "$FILTERED_MATCHES" ]]; then
  echo "发现疑似密钥或令牌，请先清理再提交："
  echo "$FILTERED_MATCHES"
  exit 1
fi

echo "密钥扫描通过。"
