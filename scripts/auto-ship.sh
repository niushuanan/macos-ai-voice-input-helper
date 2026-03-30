#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/runtime-policy.sh"
runtime_policy_init

usage() {
  cat <<'USAGE'
用法:
  scripts/auto-ship.sh --message "<commit message>" --files <file1> [file2 ...] [--skip-install] [--with-test]

参数:
  --message       必填，commit message
  --files         必填，仅提交这些文件
  --skip-install  可选，跳过 /Applications 覆盖安装
  --with-test     可选，先执行测试后再发布（默认不测）
USAGE
}
DEVELOPER_DIR_VALUE="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
commit_message=""
skip_install=0
run_tests=0
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
    --with-test)
      run_tests=1
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

if [[ "$run_tests" -eq 1 ]]; then
  echo "[1/4] 执行测试..."
  PULSETYPE_ALLOW_DEBUG_RUNTIME=1 \
  DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" \
    xcodebuild \
    -project PulseType.xcodeproj \
    -scheme PulseType \
    -configuration Debug \
    -destination "platform=macOS" \
    test
  commit_step="[2/4]"
  push_step="[3/4]"
  install_step="[4/4]"
else
  echo "[info] 默认跳过测试；如需先测请添加 --with-test"
  commit_step="[1/3]"
  push_step="[2/3]"
  install_step="[3/3]"
fi

echo "$commit_step 准备提交..."
git add -- "${files[@]}"

if git diff --cached --quiet; then
  echo "指定文件没有可提交变更"
  exit 3
fi

git commit -m "$commit_message"
commit_sha="$(git rev-parse --short HEAD)"

echo "$push_step 推送到 origin/$branch_name ..."
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

echo "$install_step 覆盖安装本地应用..."
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
if [[ "$run_tests" -eq 1 ]]; then
  echo "test: enabled"
else
  echo "test: skipped"
fi
if [[ "$skip_install" -eq 1 ]]; then
  echo "install: skipped"
else
  echo "install: $PULSETYPE_INSTALL_PATH"
fi
