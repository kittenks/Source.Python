#!/usr/bin/env bash
# One-click Linux x86 build for the eight Source.Python games.
#
# Usage:
#   scripts/ci/build-all.sh                 build all eight games
#   scripts/ci/build-all.sh css dods         build selected games only
#   scripts/ci/build-all.sh --dry-run        print the planned commands
#   SOURCEPYTHON_BUILD_DATE=2026-0925 ...   pin the archive date stamp
#
# Every game fetches the HL2SDK revision pinned in scripts/ci/sdk-pins.json and
# builds core.so/source-python.so. If PowerShell is available the dated ZIPs are
# assembled as well; otherwise copy artifacts/native/<game>/linux next to the
# Windows artifacts and run scripts/ci/package.ps1 there.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SOURCEPYTHON_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
PACKAGE=1
DRYRUN=0
GAMES=()

for argument in "$@"; do
    case "$argument" in
        --no-package) PACKAGE=0 ;;
        --dry-run) DRYRUN=1 ;;
        -*) echo "Usage: $0 [blade|bms|csgo|css|dods|hl2dm|l4d2|tf2 ...] [--no-package] [--dry-run]" >&2; exit 2 ;;
        *) GAMES+=("$argument") ;;
    esac
done
if [[ ${#GAMES[@]} -eq 0 ]]; then
    GAMES=(blade bms csgo css dods hl2dm l4d2 tf2)
fi

cd "$REPO_ROOT"

run() {
    if [[ "$DRYRUN" -eq 1 ]]; then
        printf '  %s\n' "$*"
    else
        "$@"
    fi
}

for game in "${GAMES[@]}"; do
    echo
    echo "== Fetching pinned HL2SDK for $game =="
    if [[ -n "${SP_GITHUB_PROXY:-}" ]]; then
        run env SP_GITHUB_PROXY="$SP_GITHUB_PROXY" bash ./scripts/ci/fetch-hl2sdk.sh "$game"
    else
        run bash ./scripts/ci/fetch-hl2sdk.sh "$game"
    fi
    echo "== Building Linux x86 for $game =="
    run bash ./scripts/ci/build-linux.sh "$game"
done

if [[ "$PACKAGE" -eq 1 ]] && command -v pwsh >/dev/null 2>&1; then
    echo
    echo "== Packaging ${GAMES[*]} =="
    joined="$(IFS=,; echo "${GAMES[*]}")"
    run pwsh -NoLogo -NoProfile -File ./scripts/ci/package.ps1 \
        -Branches "$joined" -RequiredPlatforms linux -SourceArchive
    echo "Archives are in $REPO_ROOT/dist"
elif [[ "$PACKAGE" -eq 1 ]]; then
    echo
    echo "pwsh was not found; skipping packaging."
    echo "Copy artifacts/native/<game>/linux next to the Windows natives and run"
    echo "scripts/ci/package.ps1 on Windows to assemble the dated ZIPs."
fi
