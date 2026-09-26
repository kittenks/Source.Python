#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <blade|bms|csgo|css|dods|hl2dm|l4d2|tf2> [destination]" >&2
    exit 2
fi

BRANCH="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SOURCEPYTHON_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
DESTINATION="${2:-${SOURCEPYTHON_SDK:-$REPO_ROOT/src/hl2sdk/$BRANCH}}"
PINS_FILE="$SCRIPT_DIR/sdk-pins.json"

case "$BRANCH" in
    blade|bms|csgo|css|dods|hl2dm|l4d2|tf2) ;;
    *) echo "Unsupported HL2SDK branch: $BRANCH" >&2; exit 2 ;;
esac

# The OrangeBox games keep platform libraries in per-architecture folders, while
# the episodic-style branches use a flat lib/public (or lib/linux) layout. The pin
# records the exact files so a wrong mirror response is rejected up front.
mapfile -t PIN_FIELDS < <(python3 - "$PINS_FILE" "$BRANCH" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    pins = json.load(stream)
entry = pins.get(sys.argv[2], {})
value = entry.get("commit", "")
if len(value) != 40 or any(ch not in "0123456789abcdef" for ch in value):
    raise SystemExit(f"Invalid pinned HL2SDK revision for {sys.argv[2]}")
print(value)
for key in ("sdk_lib", "sdk_lib_linux", "sdk_lib_linux64"):
    if entry.get(key):
        print(entry[key])
PY
)
COMMIT="${PIN_FIELDS[0]}"
SDK_LIBS=("${PIN_FIELDS[@]:1}")

is_checkout() {
    local path="${1:-$DESTINATION}"
    [[ -f "$path/public/tier1/KeyValues.h" &&
       -f "$path/tier1/KeyValues.cpp" ]] || return 1
    local library
    for library in ${SDK_LIBS[@]+"${SDK_LIBS[@]}"}; do
        [[ -f "$path/$library" ]] || return 1
    done
    return 0
}

MARKER="$DESTINATION/.source-python-sdk-commit"
if [[ -f "$MARKER" && "$(tr -d '\r\n' < "$MARKER")" == "$COMMIT" ]] && is_checkout; then
    echo "Using cached HL2SDK $BRANCH@$COMMIT at $DESTINATION"
    exit 0
fi

if [[ -e "$DESTINATION" ]]; then
    if is_checkout && [[ "${SP_FORCE_SDK:-0}" != 1 ]]; then
        echo "A different HL2SDK checkout already exists at '$DESTINATION'." >&2
        echo "Set SP_FORCE_SDK=1 to replace it." >&2
        exit 1
    fi
    rm -rf -- "$DESTINATION"
fi

mkdir -p -- "$(dirname -- "$DESTINATION")"
ARCHIVE="$(dirname -- "$DESTINATION")/.hl2sdk-$BRANCH-$COMMIT.zip"
EXTRACT="$(dirname -- "$DESTINATION")/.hl2sdk-extract-$BRANCH-$COMMIT"
SHORT_COMMIT="${COMMIT:0:7}"
trap 'rm -rf -- "$EXTRACT"' EXIT

URLS=()
if [[ -n "${SP_GITHUB_PROXY:-}" ]]; then
    URLS+=("${SP_GITHUB_PROXY%/}/https://github.com/alliedmodders/hl2sdk/archive/$COMMIT.zip")
fi
URLS+=("https://codeload.github.com/alliedmodders/hl2sdk/zip/$COMMIT")

# The HL2SDK archives are large and the GitHub link is often slow, so allow a
# long transfer, resume partial downloads and only abort on a real stall.
MAX_TIME="${SP_DOWNLOAD_MAX_TIME:-3600}"
CURL_ARGS=(-L --fail --retry 3 --retry-delay 5 --retry-all-errors
    --connect-timeout 30 --max-time "$MAX_TIME"
    --speed-limit 2048 --speed-time 120 -sS)

for URL in "${URLS[@]}"; do
    echo "Downloading HL2SDK $BRANCH@$COMMIT from $URL (max-time ${MAX_TIME}s)"
    if [[ "${SP_FRESH_DOWNLOAD:-0}" == 1 ]]; then
        rm -f -- "$ARCHIVE"
    fi
    # -C - resumes a partial archive; it is a no-op when nothing was kept.
    status=0
    curl "${CURL_ARGS[@]}" -C - -o "$ARCHIVE" "$URL" || status=$?
    if [[ $status -eq 33 ]]; then
        # The mirror refused byte ranges; start over without resuming.
        echo "The source does not support resuming; restarting the download." >&2
        rm -f -- "$ARCHIVE"
        status=0
        curl "${CURL_ARGS[@]}" -o "$ARCHIVE" "$URL" || status=$?
    fi
    if [[ $status -ne 0 || ! -s "$ARCHIVE" ]]; then
        echo "Download failed; trying the next source." >&2
        continue
    fi
    rm -rf -- "$EXTRACT"
    mkdir -p -- "$EXTRACT"
    if ! tar -xf "$ARCHIVE" -C "$EXTRACT"; then
        echo "The archive could not be extracted; trying the next source." >&2
        continue
    fi

    TOP="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    if [[ -z "$TOP" ]]; then
        echo "The archive has no top-level directory; trying the next source." >&2
        continue
    fi
    TOP_NAME="$(basename -- "$TOP")"
    if [[ "$TOP_NAME" != hl2sdk-"$SHORT_COMMIT"* ]]; then
        echo "Archive top-level directory '$TOP_NAME' does not match pinned commit; trying the next source." >&2
        continue
    fi

    # Keep the extracted tree in place: copying it would double the disk usage
    # for every SDK. Only the small Source.Python patch overlay is copied.
    CANDIDATE="$TOP"

    PATCH_DIR="$REPO_ROOT/src/patches/$BRANCH"
    if [[ -d "$PATCH_DIR" ]]; then
        echo "Applying Source.Python SDK patches from $PATCH_DIR"
        if ! cp -a -- "$PATCH_DIR"/. "$CANDIDATE"/; then
            echo "SDK patches could not be applied; trying the next source." >&2
            continue
        fi
    fi

    if ! is_checkout "$CANDIDATE"; then
        echo "The extracted HL2SDK checkout is missing required files; trying the next source." >&2
        continue
    fi

    rm -rf -- "$DESTINATION"
    if ! mv -- "$CANDIDATE" "$DESTINATION"; then
        echo "The validated SDK tree could not be installed; trying the next source." >&2
        continue
    fi
    if ! printf '%s\n' "$COMMIT" > "$MARKER"; then
        echo "The SDK commit marker could not be written; trying the next source." >&2
        rm -rf -- "$DESTINATION"
        continue
    fi
    echo "HL2SDK $BRANCH@$COMMIT is ready at $DESTINATION"
    # Keep partial archives only while they are still useful for resuming.
    rm -f -- "$ARCHIVE"
    exit 0
done

echo "Unable to download, validate, or extract HL2SDK $BRANCH@$COMMIT." >&2
exit 1
