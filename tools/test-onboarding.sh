#!/bin/bash
# Exercise the onboarding state machine and render every representative state
# without reading or changing this Mac's real Spotify or privacy state.
set -euo pipefail
cd "$(dirname "$0")/.."

output_dir="${1:-/tmp/transposify-onboarding}"
mkdir -p "$output_dir"

swift build
TRANSPOSIFY_ONBOARDING_TEST=1 .build/debug/Transposify
TRANSPOSIFY_ONBOARDING_UI_TEST=1 .build/debug/Transposify

scenarios=(
    spotify-missing
    spotify-closed
    spotify-opening
    spotify-launch-failed
    fresh
    audio-requesting
    control-pending
    audio-denied
    control-denied
    spotify-closed-after-grants
    ready
)

for appearance in light dark; do
    for scenario in "${scenarios[@]}"; do
        path="$output_dir/$appearance-$scenario.png"
        TRANSPOSIFY_SETUP_SCENARIO="$scenario" \
        TRANSPOSIFY_SETUP_APPEARANCE="$appearance" \
        TRANSPOSIFY_SETUP_SNAPSHOT="$path" \
            .build/debug/Transposify
        test -s "$path"
    done
done

echo "Rendered ${#scenarios[@]} states in light and dark mode to $output_dir"
