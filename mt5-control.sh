#!/usr/bin/env bash
# mt5-control.sh — runs INSIDE the zebra codespace.
# Polls bot-control/cmd.txt (via git) and executes commands locally,
# so the main agent controls the MT5 terminals by pushing one small
# file through GitHub instead of driving the GUI with screenshots.
# Results go to bot-control/status.txt (committed + pushed back).
set -u
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
CMD_FILE="bot-control/cmd.txt"
STATUS_FILE="bot-control/status.txt"
LOG_FILE="bot-control/control.log"
LAST_HASH=""
export DISPLAY=:99

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

find_data_dir() {
  # $1 = wine prefix; prints the terminal's data dir (the parent of MQL5).
  # Layout varies: AppData profile dir OR the install folder itself
  # (portable-style). Prefer a candidate that also has a Logs sibling.
  local prefix="$1" cand
  while IFS= read -r cand; do
    if [ -d "$cand/Logs" ]; then echo "$cand"; return; fi
  done < <(find "$prefix/drive_c" -type d -name "MQL5" 2>/dev/null | sed 's|/MQL5$||')
  find "$prefix/drive_c" -type d -name "MQL5" 2>/dev/null | head -1 | sed 's|/MQL5$||'
}

terminal_log_tail() {
  local data_dir="$1"
  local f
  f=$(ls -t "$data_dir/Logs/"*.log 2>/dev/null | head -1)
  [ -n "${f:-}" ] && iconv -f UTF-16LE -t UTF-8 "$f" 2>/dev/null | tail -30
  local m
  m=$(ls -t "$data_dir/MQL5/Logs/"*.log 2>/dev/null | head -1)
  if [ -n "${m:-}" ]; then
    echo "--- MQL5 log ---"
    iconv -f UTF-16LE -t UTF-8 "$m" 2>/dev/null | tail -30
  fi
}

do_status() {
  {
    echo "STATUS $(date '+%F %T %Z')"
    echo "== processes =="
    ps aux | grep -E "terminal64|x11vnc|websockify" | grep -v grep || true
    echo "== listeners =="
    ss -ltnp 2>/dev/null | grep -E "5900|6080" || echo "no vnc listeners"
    for pfx in "$HOME/.mt5w" "$HOME/.mt5t"; do
      echo "== prefix $pfx =="
      local dd
      dd=$(find_data_dir "$pfx")
      echo "data_dir: ${dd:-NOT FOUND}"
      [ -n "${dd:-}" ] && terminal_log_tail "$dd"
    done
  } > "$STATUS_FILE" 2>&1
  git add "$STATUS_FILE" "$LOG_FILE" 2>/dev/null
  git commit -m "mt5-control status $(date '+%H:%M:%S')" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1 && log "status pushed" || log "status push FAILED"
}

launch_with_config() {
  # $1 = wine prefix, $2 = terminal exe path (windows-style under drive_c), $3 = data dir
  local prefix="$1" exe="$2" data_dir="$3"
  local ini="$data_dir/config/startup.ini"
  mkdir -p "$data_dir/config"
  printf '[StartUp]\nSymbol=BTCUSD\nPeriod=M5\nExpert=PalmScalper\n' > "$ini"
  pkill -f "terminal64.exe" 2>/dev/null; sleep 3
  WINEPREFIX="$prefix" nohup wine "$prefix/drive_c/$exe" "/config:Z:${ini//\//\\}" >/dev/null 2>&1 &
  log "launched $exe with $ini"
}

do_attach() {
  # $1 = old|branded
  local which="$1" prefix exe src_experts dst_data
  if [ "$which" = "old" ]; then
    prefix="$HOME/.mt5w"; exe="Program Files/MetaTrader 5/terminal64.exe"
  else
    prefix="$HOME/.mt5t"; exe="Program Files/Trade Set Go MT5 Terminal/terminal64.exe"
  fi
  dst_data=$(find_data_dir "$prefix")
  if [ -z "${dst_data:-}" ]; then log "ATTACH $which: data dir not found"; do_status; return; fi
  # make sure the compiled EA is present in this terminal's Experts
  src_experts=$(find_data_dir "$HOME/.mt5w")"/MQL5/Experts"
  if [ -f "$src_experts/PalmScalper.ex5" ]; then
    cp -f "$src_experts/PalmScalper.ex5" "$dst_data/MQL5/Experts/" 2>/dev/null
    cp -f "$src_experts/PalmScalper.mq5" "$dst_data/MQL5/Experts/" 2>/dev/null
    log "EA copied to $which Experts"
  else
    log "ATTACH $which: PalmScalper.ex5 not found in old prefix"
  fi
  # a fresh "bot aktif" revives the EA even after its profit kill switch fired
  mkdir -p "$dst_data/MQL5/Files"
  : > "$dst_data/MQL5/Files/PS_RESET.flag"
  log "reset flag dropped for $which"
  launch_with_config "$prefix" "$exe" "$dst_data"
  sleep 25
  do_status
}

do_stop() {
  pkill -f "terminal64.exe" 2>/dev/null
  sleep 2
  log "STOP: all MT5 terminals killed (bot mati)"
  do_status
}

do_vnc() {
  pkill -f x11vnc 2>/dev/null; pkill -f websockify 2>/dev/null; sleep 2
  nohup x11vnc -display :99 -forever -shared -nopw -rfbport 5900 >/dev/null 2>&1 &
  nohup websockify --web /usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &
  sleep 3
  log "vnc restarted"
  do_status
}

run_cmd() {
  local cmd="$1"
  log "executing: $cmd"
  case "$cmd" in
    STATUS) do_status ;;
    ATTACH_OLD) do_attach old ;;
    ATTACH_BRANDED) do_attach branded ;;
    RESTART_VNC) do_vnc ;;
    STOP) do_stop ;;
    WAIT|"") : ;;
    *) log "unknown command: $cmd" ;;
  esac
}

log "mt5-control started in $REPO_DIR"
while true; do
  git fetch origin main >/dev/null 2>&1
  git checkout origin/main -- "$CMD_FILE" >/dev/null 2>&1
  if [ -f "$CMD_FILE" ]; then
    HASH=$(md5sum "$CMD_FILE" | cut -d' ' -f1)
    if [ "$HASH" != "$LAST_HASH" ]; then
      LAST_HASH="$HASH"
      CMD=$(head -1 "$CMD_FILE" | tr -d '\r\n')
      run_cmd "$CMD"
    fi
  fi
  sleep 15
done
