#!/usr/bin/env bash
# Builds the ProxyCodex app bundle.
#
#   ./scripts/build-app.sh [--no-sign] [--install] [--open]
#
# Environment variables used by the release workflow:
#   SIGN_IDENTITY="Developer ID Application: …"
#   UNIVERSAL_BUILD=yes
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

EXEC="AIProviderSwitcher"
INFO_PLIST="Resources/Info.plist"
ENTITLEMENTS="Resources/AIProviderSwitcher.entitlements"
OUT_DIR="$REPO_ROOT/build"
APP_BUNDLE="$OUT_DIR/$EXEC.app"

SIGN="yes"
OPEN_AFTER="no"
INSTALL="no"
INSTALL_DIR="/Applications"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
for arg in "$@"; do
    case "$arg" in
        --no-sign) SIGN="no" ;;
        --open)    OPEN_AFTER="yes" ;;
        --install) INSTALL="yes" ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if [[ "${UNIVERSAL_BUILD:-no}" == "yes" ]]; then
    echo ">> Building universal release executable…"
    swift build -c release --arch arm64 --arch x86_64
    BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    echo ">> Building release executable…"
    swift build -c release
    BUILD_DIR="$(swift build -c release --show-bin-path)"
fi
BIN="$BUILD_DIR/$EXEC"
if [[ ! -x "$BIN" ]]; then
    echo "expected executable at $BIN" >&2
    exit 1
fi

echo ">> Assembling $APP_BUNDLE …"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ROOT="$STAGING/$EXEC.app"
mkdir -p "$ROOT/Contents/MacOS" "$ROOT/Contents/Resources" "$ROOT/Contents/Frameworks"

cp "$BIN" "$ROOT/Contents/MacOS/$EXEC"
cp "$INFO_PLIST" "$ROOT/Contents/Info.plist"
cp "$REPO_ROOT/Resources/provider-proxy.py" "$ROOT/Contents/Resources/provider-proxy.py"

if [[ -f "$REPO_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$REPO_ROOT/Resources/AppIcon.icns" "$ROOT/Contents/Resources/AppIcon.icns"
fi

# Sparkle is a binary SwiftPM dependency. Preserve its full framework bundle,
# including installer helpers and XPC services required for self-updates.
SPARKLE_FRAMEWORK="$(find "$REPO_ROOT/.build" -type d -name Sparkle.framework -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle.framework was not found after swift build" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$ROOT/Contents/Frameworks/Sparkle.framework"

if ! otool -l "$ROOT/Contents/MacOS/$EXEC" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$ROOT/Contents/MacOS/$EXEC"
fi

if [[ "$SIGN" == "yes" ]]; then
    echo ">> Signing embedded framework and app…"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        # An ad-hoc build deliberately omits Hardened Runtime. Enabling library
        # validation without a Developer ID prevents the embedded Sparkle
        # framework from loading.
        codesign --force --deep --sign - "$ROOT/Contents/Frameworks/Sparkle.framework"
        codesign --force --sign - --entitlements "$ENTITLEMENTS" \
            "$ROOT/Contents/MacOS/$EXEC"
        codesign --force --sign - --entitlements "$ENTITLEMENTS" "$ROOT"
    else
        codesign --force --deep --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$ROOT/Contents/Frameworks/Sparkle.framework"
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" \
            "$ROOT/Contents/MacOS/$EXEC"
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$ROOT"
    fi
    codesign --verify --deep --strict --verbose=2 "$ROOT"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$OUT_DIR"
mv "$ROOT" "$APP_BUNDLE"

echo "✓ Built: $APP_BUNDLE"

TARGET="$APP_BUNDLE"
if [[ "$INSTALL" == "yes" ]]; then
    INSTALLED="$INSTALL_DIR/$EXEC.app"
    if pgrep -x "$EXEC" >/dev/null 2>&1; then
        echo ">> Quitting the running instance…"
        pkill -x "$EXEC" || true
        sleep 1
    fi
    echo ">> Installing to $INSTALLED …"
    rm -rf "$INSTALLED"
    ditto "$APP_BUNDLE" "$INSTALLED"
    xattr -cr "$INSTALLED"
    TARGET="$INSTALLED"
    echo "✓ Installed: $INSTALLED"
fi

echo "  Run with: open \"$TARGET\""
echo "  Launch the .app bundle so macOS registers its identifier and MenuBarExtra."

if [[ "$OPEN_AFTER" == "yes" ]]; then
    open "$TARGET"
fi
