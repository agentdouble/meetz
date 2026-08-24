#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/meeting-realtime-check.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT

say -v Thomas \
    "Bonjour, le texte doit maintenant apparaître presque immédiatement pendant que je parle dans cette réunion locale." \
    -o "$temporary_dir/francais.aiff"
say -v Samantha \
    "The English transcript must also appear live while this local meeting is still being recorded." \
    -o "$temporary_dir/english.aiff"

afconvert -f WAVE -d LEI16@16000 -c 1 \
    "$temporary_dir/francais.aiff" "$temporary_dir/francais.wav"
afconvert -f WAVE -d LEI16@16000 -c 1 \
    "$temporary_dir/english.aiff" "$temporary_dir/english.wav"

cd "$project_dir"
swift run MeetingRealtimeCheck \
    "$temporary_dir/francais.wav" \
    "$temporary_dir/english.wav"
