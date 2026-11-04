#!/bin/bash
# Fresh-Mac install of the host Ollama service. Safe to re-run.
set -euo pipefail

export PATH="/opt/homebrew/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="qwen3.8:27b-mlx"
API="http://127.0.0.1:11434"
JOB="gui/$(id -u)/com.local-ai.ollama"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This install expects an Apple Silicon Mac." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Install Homebrew from https://brew.sh and run make install again." >&2
  exit 1
fi

brew install ollama python

model_loaded() {
  curl -sf "${API}/api/ps" | python3 -c "import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if any(m.get('name')=='${MODEL}' for m in d.get('models') or []) else 1)"
}

"$ROOT/scripts/spotlight.sh"

if launchctl print "$JOB" >/dev/null 2>&1 && model_loaded; then
  echo "Ollama is already installed and ${MODEL} is loaded."
  "$ROOT/scripts/ollama.sh" status
  exit 0
fi

# `ollama list` and `ollama pull` need the server. On a fresh Mac nothing is listening yet.
"$ROOT/scripts/ollama.sh" serve

if ! ollama list | awk 'NR>1 {print $1}' | grep -qx "$MODEL"; then
  echo "Downloading ${MODEL} (about 18 GB)..."
  ollama pull "$MODEL"
fi

"$ROOT/scripts/ollama.sh" start
