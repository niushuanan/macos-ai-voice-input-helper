#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/PulseType.xcodeproj"
SCHEME="PulseType"
CONFIGURATION="${CONFIGURATION:-Debug}"
DEST_APP="/Applications/PulseType.app"
DEVELOPER_DIR_VALUE="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -d "$DEVELOPER_DIR_VALUE" ]]; then
  echo "未找到 Xcode Developer 目录：$DEVELOPER_DIR_VALUE"
  echo "请先安装 Xcode，或设置 DEVELOPER_DIR。"
  exit 2
fi

if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
  echo "未找到项目文件：$PROJECT_PATH"
  exit 2
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "未找到 xcodebuild，请先安装 Xcode。"
  exit 2
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "未找到 rsync，请先安装命令行工具。"
  exit 2
fi

echo "开始构建 ${SCHEME}（${CONFIGURATION}）..."
DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" \
  xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  build >/dev/null

echo "读取构建产物路径..."
BUILD_SETTINGS="$(
  DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" \
    xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings
)"

TARGET_BUILD_DIR="$(printf "%s\n" "$BUILD_SETTINGS" | awk -F' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')"
FULL_PRODUCT_NAME="$(printf "%s\n" "$BUILD_SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME = / { print $2; exit }')"

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${FULL_PRODUCT_NAME:-}" ]]; then
  echo "无法解析构建输出路径。"
  exit 3
fi

SOURCE_APP="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "构建完成但未找到产物：$SOURCE_APP"
  exit 3
fi

echo "准备覆盖安装到 $DEST_APP ..."
osascript -e 'try' -e 'tell application id "com.niushuanan.PulseType" to quit' -e 'end try' >/dev/null 2>&1 || true
pkill -f "/PulseType.app/Contents/MacOS/PulseType" >/dev/null 2>&1 || true

if [[ -d "$DEST_APP" ]]; then
  rm -rf "$DEST_APP" || {
    echo "删除旧版本失败，可能需要管理员权限。"
    echo "请执行：sudo rm -rf \"$DEST_APP\""
    exit 4
  }
fi

rsync -a --delete "$SOURCE_APP/" "$DEST_APP/"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f -R "$DEST_APP" >/dev/null 2>&1 || true
fi

echo
echo "已安装：$DEST_APP"
codesign -dv --verbose=2 "$DEST_APP" 2>&1 | awk '/Identifier=|Signature=|TeamIdentifier=|CDHash=/{print}'
echo
echo "现在将从 /Applications 启动..."
open "$DEST_APP"
echo "完成。"
