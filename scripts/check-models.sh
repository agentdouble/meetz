#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift run MeetingModelCheck
./scripts/check-batch.sh
./scripts/check-realtime.sh
