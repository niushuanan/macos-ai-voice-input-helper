#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/PulseType.xcodeproj"
SCHEME="PulseType"
DESTINATION="${DESTINATION:-platform=macOS}"

if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if [[ "${1:-}" == "--full" ]]; then
  echo "[test] full suite"
  exec xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    test
fi

echo "[test] fast magician suite"
echo "[test] use --full for complete suite"

cmd=(
  xcodebuild
  -quiet
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -destination "$DESTINATION"
  test
  -only-testing:PulseTypeTests/FeishuCLIProviderTests/testExecuteOAuthUsesStatusWithoutFormatFlag
  -only-testing:PulseTypeTests/FeishuCLIProviderTests/testExecuteOAuthBatchAuthUsesNoWaitLogin
  -only-testing:PulseTypeTests/FeishuCLIProviderTests/testExecuteRoutesAll35OperationsToExpectedLarkCommands
  -only-testing:PulseTypeTests/FeishuCLIProviderTests/testCalendarEventWithoutTimeUsesCreateFallbackInsteadOfAgenda
  -only-testing:PulseTypeTests/FeishuCLIProviderTests/testCalendarCreateFailsWhenEventIDMissingInSuccessEnvelope
  -only-testing:PulseTypeTests/FeishuResultVerifierTests/testStructuredWriteWithoutEvidenceFails
  -only-testing:PulseTypeTests/MagicianMusicQueryTests/testSearchQueriesSplitArtistAndSong
  -only-testing:PulseTypeTests/MagicianMusicQueryTests/testSearchQueriesDeduplicateAndTrim
)

"${cmd[@]}"
echo "[test] fast suite passed"
