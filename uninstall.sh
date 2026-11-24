#!/bin/bash
[ "$EUID" -eq 0 ] || { echo "run with sudo"; exit 1; }
L=com.github.aarif2.androidtether
U=$L.menubar
launchctl bootout system/$L 2>/dev/null
if [ -n "$SUDO_USER" ]; then
    UID_NUM="$(id -u "$SUDO_USER")"
    launchctl bootout gui/$UID_NUM/$U 2>/dev/null
fi
rm -f /Library/LaunchDaemons/$L.plist /Library/LaunchAgents/$U.plist /usr/local/sbin/androidtetherd /usr/local/bin/androidtether-ui
echo removed
