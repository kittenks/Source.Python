#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 5 ]]; then
    echo "Usage: $0 <blade|bms|csgo|css|dods|hl2dm|l4d2|tf2> [repository-root] [build-directory] [output-directory] [x86|x86_64]" >&2
    exit 2
fi

BRANCH="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${2:-${SOURCEPYTHON_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}}"
ARCH="${5:-x86}"
BUILD_DIR="${3:-$REPO_ROOT/src/Builds/Linux/$BRANCH-$ARCH}"
OUTPUT_ROOT="${4:-$REPO_ROOT/artifacts/native}"
if [[ "$ARCH" == "x86" ]]; then
    NATIVE_DIR="$OUTPUT_ROOT/$BRANCH/linux"
else
    NATIVE_DIR="$OUTPUT_ROOT/$BRANCH/linux-$ARCH"
fi

case "$BRANCH" in
    blade|bms|csgo|css|dods|hl2dm|l4d2|tf2) ;;
    *) echo "Unsupported branch: $BRANCH" >&2; exit 2 ;;
esac
case "$ARCH" in
    x86|x86_64) ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;;
esac
if [[ "$ARCH" == "x86_64" && "$BRANCH" != "hl2dm" ]]; then
    echo 'Linux x86-64 is currently limited to HL2DM.' >&2
    exit 2
fi

PINS_FILE="$SCRIPT_DIR/sdk-pins.json"
COMMIT="$(python3 - "$PINS_FILE" "$BRANCH" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    pins = json.load(stream)
print(pins[sys.argv[2]]["commit"])
PY
)"

SDK_DIR="${SOURCEPYTHON_SDK:-$REPO_ROOT/src/hl2sdk/$BRANCH}"
[[ -f "$SDK_DIR/tier1/KeyValues.cpp" ]] || {
    echo "HL2SDK is not ready at '$SDK_DIR'. Run scripts/ci/fetch-hl2sdk.sh first." >&2
    exit 1
}
if [[ "$ARCH" == "x86_64" && ! -f "$SDK_DIR/lib/public/linux64/tier1.a" ]]; then
    echo "The pinned HL2SDK checkout has no Linux x86-64 tier1 library." >&2
    exit 1
fi

mkdir -p -- "$BUILD_DIR" "$NATIVE_DIR"
cmake -S "$REPO_ROOT/src" -B "$BUILD_DIR" \
    -DBRANCH="$BRANCH" -DSOURCEPYTHON_ARCH="$ARCH" \
    -DSOURCEPYTHON_SDK="$SDK_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --parallel "${BUILD_JOBS:-2}"

CORE="$(find "$BUILD_DIR" -type f -name 'core.so' -print -quit)"
LOADER="$(find "$BUILD_DIR" -type f -name 'source-python.so' -print -quit)"
[[ -n "$CORE" && -n "$LOADER" ]] || {
    echo "The build completed but core.so or source-python.so was not produced." >&2
    exit 1
}

for binary in "$CORE" "$LOADER"; do
    if [[ "$ARCH" == "x86_64" ]]; then
        readelf -h "$binary" | grep -q 'Class:.*ELF64'
        readelf -h "$binary" | grep -Eq 'Machine:.*(Advanced Micro Devices X86-64|X86-64)'
    else
        readelf -h "$binary" | grep -q 'Class:.*ELF32'
        readelf -h "$binary" | grep -q 'Machine:.*Intel 80386'
    fi
done

rm -rf -- "$NATIVE_DIR"
mkdir -p -- "$NATIVE_DIR"
cp -- "$CORE" "$NATIVE_DIR/core.so"
cp -- "$LOADER" "$NATIVE_DIR/source-python.so"
chmod 0755 "$NATIVE_DIR/core.so" "$NATIVE_DIR/source-python.so"

SOURCE_REVISION="${SOURCEPYTHON_SOURCE_REVISION:-${GITHUB_SHA:-local-archive}}"
cat > "$NATIVE_DIR/build-info.json" <<JSON
{
  "game": "$BRANCH",
  "platform": "linux",
  "architecture": "$ARCH",
  "sdk_commit": "$COMMIT",
  "source_revision": "$SOURCE_REVISION",
  "compiler": "GCC",
  "files": ["core.so", "source-python.so"],
  "built_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

echo "Linux artifacts for $BRANCH are ready at $NATIVE_DIR"
