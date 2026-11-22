#!/usr/bin/env bash
# mt5-watchdog.sh — keep the MT5 stack alive inside a running codespace.
# Re-runs mt5-boot.sh once a minute; the boot script is idempotent.
while true; do
  bash "$(dirname "$0")/mt5-boot.sh" >>/tmp/mt5-watchdog.log 2>&1
  sleep 60
done
