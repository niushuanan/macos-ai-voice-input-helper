#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  scripts/auto-ship.sh --message "<commit message>" --files <file1> [file2 ...] [--skip-install]

参数:
  --message       必填，commit message
  --files         必填，仅提交这些文件
  --skip-install  可选，跳过 /Applications 覆盖安装
USAGE
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR_VALUE="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
commit_message=""
skip_install=0
files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message)
      shift
      if [[ $# -eq 0 ]]; then
        echo "缺少 --message 的值"
        usage
        exit 2
      fi
      commit_message="$1"
      shift
      ;;
    --files)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        files+=("$1")
        shift
      done
      ;;
    --skip-install)
      skip_install=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$commit_message" ]]; then
  echo "必须传入 --message"
  usage
  exit 2
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "必须传入 --files"
  usage
  exit 2
fi

if [[ ! -d "$DEVELOPER_DIR_VALUE" ]]; then
  echo "未找到 Xcode Developer 目录: $DEVELOPER_DIR_VALUE"
  exit 2
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "未找到 xcodebuild"
  exit 2
fi

if ! command -v git >/dev/null 2>&1; then
  echo "未找到 git"
  exit 2
fi

cd "$ROOT_DIR"

branch_name="$(git branch --show-current)"
if [[ -z "$branch_name" ]]; then
  echo "无法识别当前分支"
  exit 2
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "未找到 origin remote"
  exit 2
fi

echo "[1/4] 执行测试..."
DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  -destination "platform=macOS" \
  test

echo "[2/4] 准备提交..."
git add -- "${files[@]}"

if git diff --cached --quiet; then
  echo "指定文件没有可提交变更"
  exit 3
fi

git commit -m "$commit_message"
commit_sha="$(git rev-parse --short HEAD)"

echo "[3/4] 推送到 origin/$branch_name ..."
push_ok=0
for attempt in {1..8}; do
  echo "push attempt $attempt"
  if git push origin "$branch_name"; then
    push_ok=1
    break
  fi
  sleep 2
done

if [[ "$push_ok" -ne 1 ]]; then
  echo "推送失败，已达到最大重试次数"
  exit 4
fi

echo "[4/4] 覆盖安装本地应用..."
if [[ "$skip_install" -eq 1 ]]; then
  echo "已跳过安装步骤 (--skip-install)"
else
  "$ROOT_DIR/scripts/install-local-app.sh"
fi

echo
echo "完成"
echo "commit: $commit_sha"
echo "branch: $branch_name"
echo "push: origin/$branch_name"
if [[ "$skip_install" -eq 1 ]]; then
  echo "install: skipped"
else
  echo "install: /Applications/PulseType.app"
fi
