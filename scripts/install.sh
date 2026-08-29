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

echo "› assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TrueTone "$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
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

echo "› (re)loading service"
launchctl bootout   "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST"
launchctl kickstart -k "gui/$UID_/$LABEL"

echo "✓ TrueTone is running and will start at login."
echo "  logs:   log stream --predicate 'process == \"TrueTone\"'"
echo "  remove: scripts/uninstall.sh"
