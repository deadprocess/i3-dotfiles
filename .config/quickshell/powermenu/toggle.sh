#!/bin/sh
# ~/.config/quickshell/powermenu/toggle.sh
# Offen -> schließen, zu -> öffnen
pkill -f "qs -c powermenu" && exit 0
exec qs -c powermenu
