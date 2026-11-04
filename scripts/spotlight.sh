#!/bin/bash
# Build the two apps Spotlight launches with Cmd+Space.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${HOME}/Applications"
mkdir -p "$DEST"

compile_app() {
  local name="$1"
  local action="$2"
  local starting="$3"
  local finished="$4"
  local src
  src="$(mktemp)"
  cat >"$src" <<EOF
on run
	display notification "${starting}" with title "Local AI"
	do shell script "export PATH=/opt/homebrew/bin:\$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin; ${ROOT}/scripts/stack.sh ${action}"
	display notification "${finished}" with title "Local AI"
end run
EOF
  osacompile -o "${DEST}/${name}.app" "$src"
  rm -f "$src"
  mdimport "${DEST}/${name}.app" >/dev/null 2>&1 || true
  echo "Spotlight app: ${DEST}/${name}.app"
}

compile_app "Stop Local AI" stop \
  "Stopping Ollama and the cluster." \
  "Local AI is stopped. Its RAM is back with macOS."

compile_app "Start Local AI" start \
  "Starting Ollama and the cluster." \
  "Local AI is running."
