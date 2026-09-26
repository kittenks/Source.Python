#!/usr/bin/env bash
set -euo pipefail

# Usage: ./Build.sh <blade|bms|csgo|css|dods|hl2dm|l4d2|tf2> [x86|x86_64]
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <blade|bms|csgo|css|dods|hl2dm|l4d2|tf2> [x86|x86_64]" >&2
    exit 2
fi

BRANCH="$1"
ARCH="${2:-x86}"
STARTDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$STARTDIR/.." && pwd)"

case "$BRANCH" in
    blade|bms|csgo|css|dods|hl2dm|l4d2|tf2) ;;
    *) echo "Unsupported branch: $BRANCH" >&2; exit 2 ;;
esac
case "$ARCH" in
    x86) ;;
    x86_64)
        [[ "$BRANCH" == "hl2dm" ]] || {
            echo 'Linux x86-64 is currently limited to HL2DM.' >&2
            exit 2
        }
        ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;;
esac

bash "$REPO_ROOT/scripts/ci/fetch-hl2sdk.sh" "$BRANCH"
bash "$REPO_ROOT/scripts/ci/build-linux.sh" "$BRANCH" "$REPO_ROOT" "" "$REPO_ROOT/artifacts/native" "$ARCH"
