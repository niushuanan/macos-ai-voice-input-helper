#!/usr/bin/env bash
set -euo pipefail

APP_ID="com.niushuanan.PulseType"
APP_NAME="PulseType"
APP_INSTALL_PATH="/Applications/PulseType.app"
KEYCHAIN_SERVICE_V1="com.niushuanan.PulseType.provider-profile"
KEYCHAIN_SERVICE_V2="com.niushuanan.PulseType.provider-profile.v2"
KEYCHAIN_SERVICE_V3="com.niushuanan.PulseType.provider-profile.v3"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

print_header() {
  local title="$1"
  echo
  echo "==== $title ===="
}

print_header "运行进程"
RUNNING="$(ps aux | rg "/PulseType.app/Contents/MacOS/PulseType" | rg -v "rg /PulseType.app/Contents/MacOS/PulseType" || true)"
if [[ -z "$RUNNING" ]]; then
  echo "当前未检测到 PulseType 进程。"
else
  echo "$RUNNING"
fi

print_header "Spotlight 路径（Bundle ID）"
mdfind "kMDItemCFBundleIdentifier == '$APP_ID'" || true

print_header "关键安装路径"
if [[ -d "$APP_INSTALL_PATH" ]]; then
  echo "存在：$APP_INSTALL_PATH"
  codesign -dv --verbose=3 "$APP_INSTALL_PATH" 2>&1 \
    | awk '/Executable=|Identifier=|Signature=|TeamIdentifier=|CDHash=/{print}'
else
  echo "不存在：$APP_INSTALL_PATH"
fi

print_header "LaunchServices 记录（裁剪）"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -dump \
    | rg "com\.niushuanan\.PulseType|PulseType\.app" -n -A2 -B2 \
    | sed -n '1,220p'
else
  echo "未找到 lsregister。"
fi

print_header "权限状态（当前进程）"
swift -e '
import AVFoundation
import ApplicationServices

let mic = AVCaptureDevice.authorizationStatus(for: .audio)
let micText: String
switch mic {
case .authorized: micText = "authorized"
case .denied: micText = "denied"
case .restricted: micText = "restricted"
case .notDetermined: micText = "notDetermined"
@unknown default: micText = "unknown"
}
print("microphone:", micText)
print("accessibilityTrusted:", AXIsProcessTrusted())
' 2>/dev/null || echo "权限状态读取失败。"

print_header "App 偏好摘要"
defaults read "$APP_ID" 2>/dev/null \
  | rg "permissions\.|providers\.asr\.config|providers\.text\.config|KeyboardShortcuts_" || echo "未发现偏好数据。"

print_header "钥匙串条目摘要"
for svc in "$KEYCHAIN_SERVICE_V1" "$KEYCHAIN_SERVICE_V2" "$KEYCHAIN_SERVICE_V3"; do
  echo "-- service: $svc"
  for acc in asr.primary text.primary; do
    if security find-generic-password -s "$svc" -a "$acc" >/dev/null 2>&1; then
      echo "  $acc: found"
    else
      echo "  $acc: missing"
    fi
  done
done

echo
echo "诊断结束。"
