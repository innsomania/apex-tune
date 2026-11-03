#!/bin/bash
set -euo pipefail

if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    echo "Run with sudo: deployment/uninstall.sh" >&2
    exit 77
fi

CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console)"
if [[ "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
    CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
    /bin/launchctl bootout "gui/$CONSOLE_UID/com.apextune.status" >/dev/null 2>&1 || true
fi
/bin/launchctl bootout system/com.apextune.controller >/dev/null 2>&1 || true
/bin/rm -f /Library/LaunchAgents/com.apextune.status.plist
/bin/rm -f /Library/LaunchDaemons/com.apextune.controller.plist
/bin/rm -f "/Library/Application Support/ApexTune/status.json"

echo "ApexTune autostart services are removed. The app bundle and controller logs were retained."
