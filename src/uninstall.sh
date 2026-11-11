#!/bin/bash
# Remove Ext4 Automount.
# Usage: sudo "/Applications/Ext4 Automount.app/Contents/Resources/uninstall.sh"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
uid=$(stat -f%u /dev/console)
launchctl bootout "gui/$uid/local.ext4-automount.menu" 2>/dev/null || true
launchctl bootout system/local.ext4-automount 2>/dev/null || true
rm -f /Library/LaunchDaemons/local.ext4-automount.plist \
      /Library/LaunchAgents/local.ext4-automount.menu.plist \
      /etc/newsyslog.d/ext4-automount.conf /Users/Shared/.ext4-automount-paused
rm -rf "/Applications/Ext4 Automount.app" "/Library/Application Support/Ext4 Automount" \
       /var/run/ext4-automount
tccutil reset All local.ext4-automount >/dev/null 2>&1 || true
pkgutil --forget local.ext4-automount >/dev/null 2>&1 || true
echo "Removed Ext4 Automount. anylinuxfs was left installed (brew uninstall anylinuxfs)."
