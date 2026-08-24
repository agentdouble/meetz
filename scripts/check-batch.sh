#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/meeting-batch-check.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT

say -v Thomas \
    "Bonjour, cette réunion locale doit transcrire chaque phrase française avec précision, même après une interruption." \
    -o "$temporary_dir/francais.aiff"
say -v Samantha \
    "This local meeting must also transcribe an English conversation without switching off or losing the final sentence." \
    -o "$temporary_dir/english.aiff"

afconvert -f WAVE -d LEI16@16000 -c 1 \
    "$temporary_dir/francais.aiff" "$temporary_dir/francais.wav"
afconvert -f WAVE -d LEI16@16000 -c 1 \
    "$temporary_dir/english.aiff" "$temporary_dir/english.wav"

cd "$project_dir"
swift run MeetingBatchCheck \
    "$temporary_dir/francais.wav" \
    "$temporary_dir/english.wav"
