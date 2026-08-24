#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
project_models="$project_root/.models/FluidAudio/Models"
fluid_audio_support="$HOME/Library/Application Support/FluidAudio"
cache_models="$fluid_audio_support/Models"

mkdir -p "$fluid_audio_support" "${project_models:h}"

if [[ -L "$cache_models" ]]; then
    linked_target=$(readlink "$cache_models")
    if [[ "${linked_target:A}" == "${project_models:A}" ]]; then
        echo "Modeles FluidAudio deja relies a $project_models"
        exit 0
    fi

    echo "Refus: $cache_models est deja un lien vers $linked_target" >&2
    exit 2
fi

if [[ -e "$cache_models" ]]; then
    if [[ -e "$project_models" ]]; then
        echo "Refus: le cache et le dossier projet existent tous les deux." >&2
        echo "Cache: $cache_models" >&2
        echo "Projet: $project_models" >&2
        exit 3
    fi
    mv "$cache_models" "$project_models"
else
    mkdir -p "$project_models"
fi

ln -s "$project_models" "$cache_models"

echo "Modeles FluidAudio locaux au projet: $project_models"
echo "Cache FluidAudio relie: $cache_models -> $project_models"
