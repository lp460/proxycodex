#!/usr/bin/env bash
#
# Builds the AI Provider Switcher .app bundle (release), ad-hoc signed with the
# Hardened Runtime. Non-sandboxed so it can launch the user's Codex CLI.
#
#   ./scripts/build-app.sh [--no-sign] [--open]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

EXEC="AIProviderSwitcher"
BUNDLE_NAME="AI Provider Switcher"
INFO_PLIST="Resources/Info.plist"
ENTITLEMENTS="Resources/AIProviderSwitcher.entitlements"
BUILD_DIR="$REPO_ROOT/.build/release"
OUT_DIR="$REPO_ROOT/build"
APP_BUNDLE="$OUT_DIR/$EXEC.app"

SIGN="yes"
OPEN_AFTER="no"
for arg in "$@"; do
    case "$arg" in
        --no-sign) SIGN="no" ;;
        --open)    OPEN_AFTER="yes" ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

echo ">> Building release executable…"
swift build -c release

BIN="$BUILD_DIR/$EXEC"
if [[ ! -x "$BIN" ]]; then
    echo "expected executable at $BIN" >&2
    exit 1
fi

echo ">> Assembling $APP_BUNDLE …"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ROOT="$STAGING/$EXEC.app"
mkdir -p "$ROOT/Contents/MacOS" "$ROOT/Contents/Resources"

cp "$BIN" "$ROOT/Contents/MacOS/$EXEC"
cp "$INFO_PLIST" "$ROOT/Contents/Info.plist"
touch "$ROOT/Contents/Resources"  # ensure dir is non-empty

# Optional icon if present.
if [[ -f "$REPO_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$REPO_ROOT/Resources/AppIcon.icns" "$ROOT/Contents/Resources/AppIcon.icns"
fi

if [[ "$SIGN" == "yes" ]]; then
    echo ">> Ad-hoc signing with Hardened Runtime…"
    codesign --force --options runtime --sign - \
        --entitlements "$ENTITLEMENTS" \
        "$ROOT/Contents/MacOS/$EXEC"
    codesign --force --options runtime --sign - \
        --entitlements "$ENTITLEMENTS" \
        "$ROOT"
    echo ">> Verifying signature…"
    codesign --verify --strict --verbose=2 "$ROOT" 2>&1 | sed 's/^/   /' || true
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$OUT_DIR"
mv "$ROOT" "$APP_BUNDLE"

echo ""
echo "✓ Built: $APP_BUNDLE"
echo "  Run with: open \"$APP_BUNDLE\""
echo "  (or)      \"$APP_BUNDLE/Contents/MacOS/$EXEC\""

if [[ "$OPEN_AFTER" == "yes" ]]; then
    open "$APP_BUNDLE"
fi
