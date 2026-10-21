#!/bin/bash
# Build only. Provisioning, upload and deployment are separate explicit steps.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${XBOT_TEAM_ID:?Set XBOT_TEAM_ID to your Apple developer team}"
: "${XBOT_BUNDLE_ID:?Set XBOT_BUNDLE_ID to the registered xbot App ID}"
TASK_OUTPUT="${XBOT_ARCHIVE_PATH:-/tmp/xbot-ios-release/Xbot.xcarchive}"
TASK_PUSH=("XBOT_PUSH_ENABLED=NO")
if [[ "${XBOT_PUSH_ENABLED:-NO}" == YES ]]; then
    TASK_ENVIRONMENT="${APS_ENVIRONMENT:-production}"
    [[ "$TASK_ENVIRONMENT" == production || "$TASK_ENVIRONMENT" == development ]] || { echo 'APS_ENVIRONMENT must be development or production'; exit 1; }
    TASK_PUSH=("XBOT_PUSH_ENABLED=YES" "CODE_SIGN_ENTITLEMENTS=Sources/XbotApp/Push.entitlements" "APS_ENVIRONMENT=$TASK_ENVIRONMENT")
fi
cd "$TASK_ROOT"
xcodebuild -project Xbot.xcodeproj -scheme Xbot -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$TASK_OUTPUT" \
    "DEVELOPMENT_TEAM=$XBOT_TEAM_ID" "PRODUCT_BUNDLE_IDENTIFIER=$XBOT_BUNDLE_ID" \
    "${TASK_PUSH[@]}" archive
