#!/bin/bash
# Build TrueTone, assemble a .app, and register a LaunchAgent so it runs at
# login and restarts if it ever crashes. Re-run any time to update.
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.dmitriy.truetone"
APP="$HOME/Applications/TrueTone.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$APP/Contents/MacOS/TrueTone"
UID_="$(id -u)"

echo "› building release…"
swift build -c release

echo "› building icon"
swift scripts/make-icon.swift >/dev/null

echo "› assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TrueTone "$BIN"
cp Resources/Info.plist   "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# ad-hoc sign so the window server / TCC treat it as a stable identity
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "› writing LaunchAgent $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key> <array><string>$BIN</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key>      <string>Interactive</string>
    <key>LimitLoadToSessionType</key> <string>Aqua</string>
    <key>StandardErrorPath</key> <string>/tmp/truetone.log</string>
</dict>
</plist>
EOF
chmod 644 "$PLIST"

echo "› installing 'truetone' command"
chmod +x scripts/truetone
if ln -sf "$PWD/scripts/truetone" /usr/local/bin/truetone 2>/dev/null; then
    echo "  → /usr/local/bin/truetone"
else
    mkdir -p "$HOME/.local/bin"
    ln -sf "$PWD/scripts/truetone" "$HOME/.local/bin/truetone"
    echo "  → ~/.local/bin/truetone   (add ~/.local/bin to PATH if needed)"
fi

echo "› (re)loading service"
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
pkill -x TrueTone 2>/dev/null || true
sleep 1
if ! launchctl bootstrap "gui/$UID_" "$PLIST" 2>/dev/null; then
    # already registered / transitioning — just (re)start it
    launchctl enable "gui/$UID_/$LABEL" 2>/dev/null || true
fi
# kickstart can answer "Domain does not support specified action" while the
# service is still settling from the bootout above. That is not fatal — but with
# `set -e` it aborted the script after a perfectly good install, leaving the app
# not running and the user staring at an error.
launchctl kickstart -k "gui/$UID_/$LABEL" 2>/dev/null || true
sleep 1
pgrep -x TrueTone >/dev/null || open -a "$APP" 2>/dev/null || true
sleep 1

if ! pgrep -x TrueTone >/dev/null; then
    echo "! Installed, but it did not start."
    echo "  Open TrueTone from ~/Applications, or check /tmp/truetone.log"
    exit 1
fi

command -v m1ddc >/dev/null || {
    echo "! m1ddc not found — colour will work, brightness control will not."
    echo "  brew install m1ddc, then re-run this script."
}

echo "✓ TrueTone is running and will start at login."
echo "  hide/show icon:  truetone hide  /  truetone show   (or hotkey ⌃⌥⌘T)"
echo "  logs:            /tmp/truetone.log"
echo "  remove:          scripts/uninstall.sh"
