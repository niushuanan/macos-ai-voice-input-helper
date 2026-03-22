#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="com.niushuanan.PulseType"
APP_NAME="PulseType"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
declare -a LEGACY_KEYCHAIN_SERVICES=(
  "com.niushuanan.PulseType.provider-profile"
  "com.niushuanan.PulseType.provider-profile.v2"
  "com.niushuanan.PulseType.provider-profile.v3"
)

echo "PulseType 一次性修复开始..."

echo
echo "1) 退出正在运行的 $APP_NAME"
osascript -e 'try' -e "tell application id \"$APP_ID\" to quit" -e 'end try' >/dev/null 2>&1 || true
pkill -f "/PulseType.app/Contents/MacOS/PulseType" >/dev/null 2>&1 || true
sleep 1

echo
echo "2) 注销旧路径"
declare -a CANDIDATES=()
while IFS= read -r path; do
  [[ -n "$path" ]] && CANDIDATES+=("$path")
done < <(mdfind "kMDItemCFBundleIdentifier == '$APP_ID'" 2>/dev/null || true)

CANDIDATES+=("$ROOT_DIR/build/Debug/PulseType.app")
CANDIDATES+=("$ROOT_DIR/build/Release/PulseType.app")

if [[ -x "$LSREGISTER" ]]; then
  declare -A SEEN=()
  for path in "${CANDIDATES[@]}"; do
    [[ -z "$path" ]] && continue
    if [[ -n "${SEEN[$path]:-}" ]]; then
      continue
    fi
    SEEN[$path]=1
    if [[ -e "$path" ]]; then
      echo "  - unregister $path"
      "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
    fi
  done
  "$LSREGISTER" -gc >/dev/null 2>&1 || true
else
  echo "  - 未找到 lsregister，跳过。"
fi

echo
echo "3) 清理仓库内旧构建残留"
for path in "$ROOT_DIR/build/Debug/PulseType.app" "$ROOT_DIR/build/Release/PulseType.app"; do
  if [[ -e "$path" ]]; then
    rm -rf "$path"
    echo "  - removed $path"
  fi
done

echo
echo "4) 重置权限记录（系统会在下次请求时再次弹窗）"
tccutil reset Accessibility "$APP_ID" || true
tccutil reset Microphone "$APP_ID" || true
echo "  - 已执行 tcc reset"

echo
echo "5) 清理旧钥匙串条目与废弃偏好"
for svc in "${LEGACY_KEYCHAIN_SERVICES[@]}"; do
  for acc in asr.primary text.primary; do
    security delete-generic-password -s "$svc" -a "$acc" >/dev/null 2>&1 || true
  done
done
defaults delete "$APP_ID" "providers.keychain.rebind.required" >/dev/null 2>&1 || true
defaults delete "$APP_ID" "KeyboardShortcuts_stopSession" >/dev/null 2>&1 || true
echo "  - 旧钥匙串服务与废弃本地标记已清理"

echo
echo "修复步骤已执行。下一步："
echo "  1) ./scripts/install-local-app.sh"
echo "  2) 打开 App 后在“模型”页重新保存一次两把密钥"
echo "  3) 在“设置”页重新申请麦克风与辅助功能"
