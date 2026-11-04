#!/bin/bash
# Stop or start Ollama and the Colima cluster together.
set -euo pipefail

export PATH="/opt/homebrew/bin:${HOME}/.local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Local AI\"" >/dev/null 2>&1 || true
}

cmd_stop() {
  notify "Stopping Ollama and the cluster."
  "$ROOT/scripts/ollama.sh" stop
  if command -v colima >/dev/null 2>&1; then
    "$ROOT/scripts/cluster.sh" down
  fi
  notify "Local AI is stopped. Its RAM is back with macOS."
}

cmd_start() {
  notify "Starting Ollama and the cluster. The first load can take a few minutes."
  "$ROOT/scripts/ollama.sh" start
  if command -v colima >/dev/null 2>&1; then
    "$ROOT/scripts/cluster.sh" up
  fi
  notify "Local AI is running."
}

usage() {
  echo "usage: $0 {stop|start}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
case "$1" in
  stop) cmd_stop ;;
  start) cmd_start ;;
  *) usage ;;
esac
