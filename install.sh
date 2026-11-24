#!/bin/bash
set -e
[ "$EUID" -eq 0 ] || { echo "run with sudo"; exit 1; }
D="$(cd "$(dirname "$0")" && pwd)"
L=com.github.aarif2.androidtether
U=$L.menubar

wait_unloaded() {
    local target="$1" i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$target" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
}

launchctl bootout system/$L 2>/dev/null || true
wait_unloaded system/$L

make -C "$D" install PREFIX=/usr/local
install -o root -g wheel -m 644 "$D/$L.plist" /Library/LaunchDaemons/$L.plist
install -o root -g wheel -m 644 "$D/$U.plist" /Library/LaunchAgents/$U.plist

launchctl enable system/$L 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/$L.plist

if [ -n "$SUDO_USER" ]; then
    UID_NUM="$(id -u "$SUDO_USER")"
    launchctl bootout gui/$UID_NUM/$U 2>/dev/null || true
    wait_unloaded gui/$UID_NUM/$U
    launchctl enable gui/$UID_NUM/$U 2>/dev/null || true
    launchctl bootstrap gui/$UID_NUM /Library/LaunchAgents/$U.plist
fi
echo "installed. log: /var/log/androidtether.log"
