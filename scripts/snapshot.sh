#!/bin/zsh
# Launches the debug build, captures the window and quits. Usage: scripts/snapshot.sh name [app args…]
set -e
APP="build/DerivedData/Build/Products/Debug/NiimLabel.app/Contents/MacOS/NiimLabel"
OUT="$HOME/Library/Containers/nl.computhings.niimlabel/Data/tmp"
pkill -x NiimLabel 2>/dev/null || true
rm -f "$OUT/$1.png" "$OUT/$1.sheet.png"
"$APP" -snapshot "$1.png" "${@:2}" >/dev/null 2>&1 &
sleep 6
pkill -x NiimLabel 2>/dev/null || true
ls "$OUT"/$1*
