#!/usr/bin/env bash
set -euo pipefail

KEYCHAIN_SERVICE="com.niushuanan.PulseType.provider-profile.v3"
ASR_ACCOUNT="asr.primary"
TEXT_ACCOUNT="text.primary"
TRUSTED_APP="/Applications/PulseType.app"

save_key() {
  local account="$1"
  local key_value="$2"

  if [[ -z "$key_value" ]]; then
    return 0
  fi

  local -a command=(
    security add-generic-password
    -U
    -A
    -a "$account"
    -s "$KEYCHAIN_SERVICE"
    -w "$key_value"
  )

  "${command[@]}" >/dev/null
}

read_secret() {
  local prompt="$1"
  local output=""
  read -r -s -p "$prompt" output
  echo
  printf "%s" "$output"
}

echo "PulseType 本地密钥初始化"
echo "服务名：$KEYCHAIN_SERVICE"
echo "账号位：$ASR_ACCOUNT / $TEXT_ACCOUNT"
echo
echo "提示：这个脚本是兼容入口，推荐优先在 App 的“模型”页保存密钥。"
echo "提示：直接回车可跳过该项。"
echo

ASR_KEY="${PULSETYPE_ASR_KEY:-}"
TEXT_KEY="${PULSETYPE_TEXT_KEY:-}"

if [[ -z "$ASR_KEY" ]]; then
  ASR_KEY="$(read_secret "请输入 ASR API Key（默认用于 Qwen3-ASR-Flash）：")"
fi

if [[ -z "$TEXT_KEY" ]]; then
  TEXT_KEY="$(read_secret "请输入文本 API Key（默认用于 DeepSeek）：")"
fi

save_key "$ASR_ACCOUNT" "$ASR_KEY"
save_key "$TEXT_ACCOUNT" "$TEXT_KEY"

if [[ -n "$ASR_KEY" ]]; then
  echo "已写入 ASR 密钥到钥匙串。"
else
  echo "ASR 密钥未写入（你选择了跳过）。"
fi

if [[ -n "$TEXT_KEY" ]]; then
  echo "已写入文本密钥到钥匙串。"
else
  echo "文本密钥未写入（你选择了跳过）。"
fi

echo
if [[ ! -d "$TRUSTED_APP" ]]; then
  echo "注意：未检测到 /Applications/PulseType.app，首次使用时可能仍需在 App 内重新保存一次密钥。"
fi
echo "完成。你可以打开 PulseType -> 模型页点“测试 ASR / 测试文本模型”验证配置。"
