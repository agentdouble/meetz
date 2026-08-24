#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-debug}
app_dir="$project_dir/.build/Meeting.app"
contents_dir="$app_dir/Contents"
binary_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
entitlements_path="$project_dir/Support/Meeting.entitlements"
default_signing_identity="Developer ID Application: COLLOVRAY JEREMY (LJ44JWQ586)"
signing_identity=${MEETING_CODESIGN_IDENTITY:-$default_signing_identity}

cd "$project_dir"
swift build --configuration "$configuration" --product MeetingApp >&2

bin_dir=$(swift build --configuration "$configuration" --show-bin-path)
binary_path="$bin_dir/MeetingApp"

if [[ -d "$app_dir" ]]; then
    chmod -R u+w "$app_dir"
fi

mkdir -p "$binary_dir" "$resources_dir"
cp "$binary_path" "$binary_dir/MeetingApp"
cp "$project_dir/Support/MeetingInfo.plist" "$contents_dir/Info.plist"

# Une interruption de codesign peut laisser un CodeResources qui reference
# le fichier de travail MeetingApp.cstemp. Le bundle est genere localement :
# retirer uniquement ces artefacts avant de recreer une signature complete.
rm -rf "$contents_dir/_CodeSignature"
rm -f "$binary_dir"/*.cstemp(N)

for resource_bundle in "$bin_dir"/*.bundle(N); do
    destination="$resources_dir/${resource_bundle:t}"
    mkdir -p "$destination"
    ditto "$resource_bundle" "$destination"
done

if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
    echo "Identite de signature macOS introuvable : $signing_identity" >&2
    echo "Definissez MEETING_CODESIGN_IDENTITY avec une identite stable valide." >&2
    exit 1
fi

codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --entitlements "$entitlements_path" \
    --sign "$signing_identity" \
    --identifier com.jeremy.meeting \
    "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
