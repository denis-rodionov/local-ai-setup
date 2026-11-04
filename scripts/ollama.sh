#!/bin/bash
# Start, stop, and inspect the macOS Ollama login agent.
set -euo pipefail

LABEL="com.local-ai.ollama"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/host/launchagents/$LABEL.plist"
DEST="${HOME}/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="${HOME}/Library/Logs/local-ai"
DOMAIN="gui/$(id -u)"
JOB="$DOMAIN/$LABEL"
API="http://127.0.0.1:11434"
MODEL="qwen3.8:27b-mlx"

install_plist() {
  mkdir -p "${HOME}/Library/LaunchAgents" "$LOG_DIR"
  cp "$SRC" "$DEST"
}

listeners() {
  lsof -nP -iTCP:11434 -sTCP:LISTEN -t 2>/dev/null || true
}

stop_listeners() {
  local pids
  pids="$(listeners)"
  if [[ -z "$pids" ]]; then
    return 0
  fi
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -z "$(listeners)" ]] && return 0
    sleep 0.3
  done
  pids="$(listeners)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
  fi
}

bootout() {
  launchctl bootout "$JOB" 2>/dev/null || true
}

wait_for_api() {
  local _
  for _ in $(seq 1 30); do
    if curl -sf "$API/api/tags" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "Ollama did not answer on ${API} within 30s" >&2
  echo "Last log lines:" >&2
  tail -n 40 "$LOG_DIR/ollama.log" >&2 || true
  return 1
}

warm_model() {
  echo "Loading ${MODEL} (first load can take a minute)..."
  curl -sS -m 300 "$API/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"ok\",\"stream\":false,\"keep_alive\":-1,\"options\":{\"num_predict\":1}}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("response","(empty response)"))'
}

cmd_serve() {
  install_plist
  bootout
  stop_listeners
  launchctl enable "$JOB"
  launchctl bootstrap "$DOMAIN" "$DEST"
  wait_for_api
}

cmd_start() {
  cmd_serve
  warm_model
  echo
  cmd_status
}

cmd_stop() {
  bootout
  stop_listeners
  echo "Ollama is stopped. It will start again at next login."
  echo "Use 'make ollama-disable' to keep it off across logins."
}

cmd_disable() {
  bootout
  stop_listeners
  launchctl disable "$JOB"
  echo "Login start is off. 'make ollama-enable' turns it back on."
}

cmd_enable() {
  launchctl enable "$JOB"
  echo "Login start is on. Ollama will start at next login."
  echo "Use 'make ollama-start' to start it now."
}

cmd_status() {
  echo "job: $JOB"
  if launchctl print "$JOB" >/dev/null 2>&1; then
    local pid state
    pid="$(launchctl print "$JOB" | awk '/^[[:space:]]*pid = /{print $3; exit}')"
    state="$(launchctl print "$JOB" | awk '/^[[:space:]]*state = /{print $3; exit}')"
    echo "agent: loaded  state=${state:-unknown}  pid=${pid:-none}"
  else
    echo "agent: not loaded"
  fi
  if launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -q "\"$LABEL\" => disabled"; then
    echo "login start: disabled"
  else
    echo "login start: enabled"
  fi
  if curl -sf "$API/api/tags" >/dev/null; then
    echo "api: up"
    curl -sf "$API/api/ps" | python3 -c 'import json,sys; d=json.load(sys.stdin); ms=d.get("models") or []; print("loaded:", ", ".join(m.get("name","?") for m in ms) if ms else "loaded: (none)")'
  else
    echo "api: down"
  fi
}

usage() {
  echo "usage: $0 {start|serve|stop|status|enable|disable}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
case "$1" in
  start) cmd_start ;;
  serve) cmd_serve ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  *) usage ;;
esac
