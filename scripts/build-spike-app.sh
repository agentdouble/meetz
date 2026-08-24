#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-debug}
app_dir="$project_dir/.build/MeetingCaptureSpike.app"
contents_dir="$app_dir/Contents"
binary_dir="$contents_dir/MacOS"

cd "$project_dir"
swift build --configuration "$configuration" --product MeetingCaptureSpike >&2

binary_path=$(swift build --configuration "$configuration" --show-bin-path)/MeetingCaptureSpike

mkdir -p "$binary_dir"
cp "$binary_path" "$binary_dir/MeetingCaptureSpike"
cp "$project_dir/Support/Info.plist" "$contents_dir/Info.plist"

codesign --force --sign - --identifier com.jeremy.meeting.capture-spike "$app_dir"

echo "$app_dir"
