#!/bin/bash
# Stop TrueTone, remove its LaunchAgent and the installed .app.
set -euo pipefail

LABEL="com.dmitriy.truetone"
UID_="$(id -u)"

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
rm -f  "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/TrueTone.app"

echo "✓ removed. (The app restores display gamma on exit.)"
