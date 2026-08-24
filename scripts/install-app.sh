#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
configuration=${1:-debug}
built_app=$($script_dir/build-app.sh "$configuration")
installed_app="/Applications/Meeting.app"

# Le chemin d'installation fait partie de l'identite observee par macOS/TCC.
# On conserve donc toujours le meme bundle signe au meme emplacement.
mkdir -p "$installed_app"
ditto "$built_app" "$installed_app"
codesign --verify --deep --strict "$installed_app"

echo "$installed_app"
