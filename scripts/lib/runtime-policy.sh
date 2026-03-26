#!/usr/bin/env bash
set -euo pipefail

runtime_policy_init() {
  local script_dir root_dir plist_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root_dir="$(cd "$script_dir/../.." && pwd)"
  plist_path="$root_dir/Config/AppRuntimePolicy.plist"

  if [[ ! -f "$plist_path" ]]; then
    echo "未找到 runtime policy 配置：$plist_path" >&2
    exit 2
  fi

  if [[ ! -x "/usr/libexec/PlistBuddy" ]]; then
    echo "未找到 /usr/libexec/PlistBuddy，无法读取 runtime policy。" >&2
    exit 2
  fi

  export PULSETYPE_ROOT_DIR="$root_dir"
  export PULSETYPE_RUNTIME_POLICY_PLIST="$plist_path"
  export PULSETYPE_APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :appName' "$plist_path")"
  export PULSETYPE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :bundleIdentifier' "$plist_path")"
  export PULSETYPE_INSTALL_PATH="$(/usr/libexec/PlistBuddy -c 'Print :installPath' "$plist_path")"
  export PULSETYPE_DEBUG_RUNTIME_ENV_KEY="$(/usr/libexec/PlistBuddy -c 'Print :debugRuntimeEnvironmentKey' "$plist_path")"
  export PULSETYPE_LSREGISTER_PATH="$(/usr/libexec/PlistBuddy -c 'Print :launchServicesToolPath' "$plist_path")"
}
