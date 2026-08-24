#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}

cd "$project_dir"
swift run CaptureCoreChecks
./scripts/build-spike-app.sh
codesign --verify --deep --strict .build/MeetingCaptureSpike.app
./scripts/build-app.sh
codesign --verify --deep --strict .build/Meeting.app
plutil -lint Support/Info.plist Support/MeetingInfo.plist Support/Meeting.entitlements

entitlements=$(codesign -d --entitlements - .build/Meeting.app 2>/dev/null)
if [[ "$entitlements" != *"com.apple.security.device.audio-input"* ]]; then
    echo "ERROR: Meeting.app ne contient pas l'entitlement microphone requis" >&2
    exit 1
fi

echo "OK: Meeting capture spike checks passed"
