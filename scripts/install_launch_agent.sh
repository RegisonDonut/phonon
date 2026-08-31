#!/usr/bin/env bash
# Install the local development server as a per-user launchd service.
set -euo pipefail

cd "$(dirname "$0")/.."
PHONON_ROOT="$(pwd -P)"
TEMPLATE="$PHONON_ROOT/Bundle/com.phonon.omni.plist"
TARGET="$HOME/Library/LaunchAgents/com.phonon.omni.plist"
LABEL="com.phonon.omni"
DOMAIN="gui/$(id -u)"

mkdir -p "$HOME/Library/LaunchAgents"
cp "$TEMPLATE" "$TARGET"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $PHONON_ROOT/scripts/start_server.sh" "$TARGET"
/usr/libexec/PlistBuddy -c "Set :WorkingDirectory $PHONON_ROOT" "$TARGET"
plutil -lint "$TARGET"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$TARGET"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "Installed $LABEL from $PHONON_ROOT"
