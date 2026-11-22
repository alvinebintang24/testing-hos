#!/usr/bin/env bash
# mt5-boot.sh — bring up the virtual display + MT5 terminal on zebra.
# Safe to run repeatedly: every component starts only if not running.
export WINEPREFIX="$HOME/.mt5w"
export DISPLAY=:99
MT5DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"

pgrep -f "Xvfb :99" >/dev/null 2>&1 || { Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 & sleep 1; }
pgrep -x openbox >/dev/null 2>&1 || { openbox >/tmp/openbox.log 2>&1 & }
pgrep -f "terminal64.exe" >/dev/null 2>&1 || { (cd "$MT5DIR" && nohup wine terminal64.exe >/tmp/mt5.log 2>&1 &) }
echo "mt5-boot: display + terminal ensured at $(date)"
