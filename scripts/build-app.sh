#!/usr/bin/env bash
#
# Builds the AI Provider Switcher .app bundle (release), ad-hoc signed with the
# Hardened Runtime. Non-sandboxed so it can launch the user's Codex CLI.
#
#   ./scripts/build-app.sh [--no-sign] [--install] [--open]
#
# --install copies the bundle to /Applications, so the app no longer depends on
# this checkout staying where it is.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

EXEC="AIProviderSwitcher"
BUNDLE_NAME="AI Provider Switcher"
INFO_PLIST="Resources/Info.plist"
ENTITLEMENTS="Resources/AIProviderSwitcher.entitlements"
BUILD_DIR="$REPO_ROOT/.build/release"
SCRATCH_DIR="${AI_PROVIDER_SWITCHER_SCRATCH_DIR:-.build}"
BUILD_DIR="$REPO_ROOT/$SCRATCH_DIR/release"
OUT_DIR="$REPO_ROOT/build"
APP_BUNDLE="$OUT_DIR/$EXEC.app"

SIGN="yes"
OPEN_AFTER="no"
INSTALL="no"
INSTALL_DIR="/Applications"
for arg in "$@"; do
    case "$arg" in
        --no-sign) SIGN="no" ;;
        --open)    OPEN_AFTER="yes" ;;
        --install) INSTALL="yes" ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

echo ">> Building release executable…"
swift build -c release --scratch-path "$SCRATCH_DIR"

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
# SwiftPM emits localized resources in a resource bundle. Copy the language
# directories directly next to Info.plist so Bundle.main can resolve them.
RESOURCE_BUNDLE="$BUILD_DIR/${EXEC}_AIProviderSwitcher.bundle"
for language_bundle in "$RESOURCE_BUNDLE"/*.lproj; do
    [[ -d "$language_bundle" ]] && cp -R "$language_bundle" "$ROOT/Contents/Resources/"
done
# The adapter proxy must ship inside the bundle: an installed app cannot rely on
# this checkout still being there.
cp "$REPO_ROOT/Resources/provider-proxy.py" "$ROOT/Contents/Resources/provider-proxy.py"

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

TARGET="$APP_BUNDLE"
if [[ "$INSTALL" == "yes" ]]; then
    INSTALLED="$INSTALL_DIR/$EXEC.app"
    # A running instance would keep the old binary and the old proxies alive.
    if pgrep -x "$EXEC" >/dev/null 2>&1; then
        echo ">> Quitting the running instance…"
        pkill -x "$EXEC" || true
        sleep 1
    fi
    echo ">> Installing to $INSTALLED …"
    rm -rf "$INSTALLED"
    # ditto preserves the bundle layout; the xattr sweep removes quarantine and
    # Finder metadata, which codesign rejects as "detritus".
    ditto "$APP_BUNDLE" "$INSTALLED"
    xattr -cr "$INSTALLED"
    if [[ "$SIGN" == "yes" ]]; then
        echo ">> Signing the installed copy…"
        codesign --force --options runtime --sign - \
            --entitlements "$ENTITLEMENTS" "$INSTALLED/Contents/MacOS/$EXEC"
        codesign --force --options runtime --sign - \
            --entitlements "$ENTITLEMENTS" "$INSTALLED"
        codesign --verify --strict --verbose=2 "$INSTALLED" 2>&1 | sed 's/^/   /'
    fi
    TARGET="$INSTALLED"
    echo "✓ Installed: $INSTALLED"
fi

echo "  Run with: open \"$TARGET\""
echo "  Important: launch the .app bundle (not Contents/MacOS/$EXEC directly) so macOS registers the bundle identifier and MenuBarExtra."

if [[ "$OPEN_AFTER" == "yes" ]]; then
    open "$TARGET"
fi
