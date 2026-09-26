#!/bin/bash
# One-command install of the latest released build. No Xcode, no Homebrew, and
# no Gatekeeper dance — the download quarantine is cleared here rather than
# being left as a scary dialog and a command the user has to find in a README.
#
#   curl -fsSL https://raw.githubusercontent.com/SaintD1smas/TrueTone/master/scripts/download-install.sh | bash
#
set -euo pipefail

REPO="SaintD1smas/TrueTone"
APP="$HOME/Applications/TrueTone.app"
LABEL="com.dmitriy.truetone"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

die() { echo "✗ $*" >&2; exit 1; }

# --- this build is Apple Silicon only, and the sensor lives in the laptop ---
[ "$(uname -s)" = "Darwin" ] || die "macOS only."
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon only — this build is arm64."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] 2>/dev/null \
    || die "Needs macOS 14 or newer (you have $(sw_vers -productVersion))."

echo "› finding the latest release"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | sed -n 's/.*"browser_download_url": *"\([^"]*\.zip\)".*/\1/p' | head -1)
[ -n "$URL" ] || die "No release asset found. Install from source instead: https://github.com/$REPO"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "› downloading $(basename "$URL")"
curl -fsSL -o "$TMP/app.zip" "$URL"

echo "› unpacking"
ditto -x -k "$TMP/app.zip" "$TMP/out"
SRC="$TMP/out/TrueTone.app"
[ -d "$SRC" ] || die "Archive did not contain TrueTone.app."

# Verifies the bundle survived the download intact. It is ad-hoc signed, so this
# proves integrity, not identity — there is no Apple Developer ID behind it.
echo "› verifying the bundle"
codesign --verify --deep --strict "$SRC" 2>/dev/null \
    || die "Signature check failed — the download is corrupt. Try again."

# The whole point of this script: a file downloaded by curl or a browser carries
# com.apple.quarantine, and macOS then refuses to open an app that Apple has not
# notarised, with a message that reads like the file is broken.
xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true

echo "› installing to $APP"
pkill -x TrueTone 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$SRC" "$APP"

if [ -f "$PLIST" ]; then
    echo "› re-loading the existing login item"
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
    sleep 1
fi

pgrep -x TrueTone >/dev/null || open -a "$APP" 2>/dev/null || true
sleep 2
pgrep -x TrueTone >/dev/null || die "Installed, but it would not start. See /tmp/truetone.log"

echo
echo "✓ TrueTone is running."
echo "  It has no Dock icon — look for a half-filled ring in the menu bar (⌃⌥⌘T if macOS hides it)."
echo "  Turn on 'Start at login' in its menu to keep it across reboots."

command -v m1ddc >/dev/null || {
    echo
    echo "! m1ddc is not installed, so brightness control will do nothing."
    echo "  Colour adaptation still works. To enable brightness:  brew install m1ddc"
}
