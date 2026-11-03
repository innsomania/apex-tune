#!/bin/bash
set -euo pipefail

if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    echo "Run with sudo: deployment/install.sh" >&2
    exit 77
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT_DIR/app/build/ApexTune.app"
APP_DST="/Applications/ApexTune.app"
DAEMON_SRC="$ROOT_DIR/deployment/com.apextune.controller.plist"
AGENT_SRC="$ROOT_DIR/deployment/com.apextune.status.plist"
DAEMON_DST="/Library/LaunchDaemons/com.apextune.controller.plist"
AGENT_DST="/Library/LaunchAgents/com.apextune.status.plist"

if /usr/bin/pgrep -f '^/Applications/ApexTune\.app/Contents/MacOS/ApexTune --control$' >/dev/null; then
    echo "A legacy interactive control process is running. Quit that ApexTune control session before installing the daemon." >&2
    exit 75
fi

/usr/bin/make -C "$ROOT_DIR/app" app
/usr/bin/install -d -o root -g wheel -m 0755 "/Library/Application Support/ApexTune" "/Library/Logs/ApexTune"
/usr/bin/ditto "$APP_SRC" "$APP_DST"
/usr/sbin/chown -R root:wheel "$APP_DST"
/bin/chmod -R go-w "$APP_DST"
/usr/bin/install -o root -g wheel -m 0644 "$DAEMON_SRC" "$DAEMON_DST"
/usr/bin/install -o root -g wheel -m 0644 "$AGENT_SRC" "$AGENT_DST"

/bin/launchctl bootout system/com.apextune.controller >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$DAEMON_DST"

CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console)"
if [[ "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
    CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
    /bin/launchctl bootout "gui/$CONSOLE_UID/com.apextune.status" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "gui/$CONSOLE_UID" "$AGENT_DST"
fi

echo "ApexTune daemon and per-user status menu are installed."
echo "Check: launchctl print system/com.apextune.controller"
echo "Logs: /Library/Logs/ApexTune/controller.log"
