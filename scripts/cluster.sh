#!/bin/bash
# Start, stop, and resize the Colima k3s profile.
set -euo pipefail

export PATH="/opt/homebrew/bin:${HOME}/.local/bin:${PATH}"

PROFILE="ai"
CONTEXT="local"
COLIMA_CONTEXT="colima-ai"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/colima/ai.yaml"
DEST="${HOME}/.colima/${PROFILE}/colima.yaml"

require_colima() {
  if ! command -v colima >/dev/null 2>&1; then
    echo "Install Colima first: brew install colima" >&2
    exit 1
  fi
}

profile_running() {
  colima status --profile "$PROFILE" >/dev/null 2>&1
}

ensure_profile_file() {
  mkdir -p "$(dirname "$DEST")"
  if [[ ! -f "$DEST" ]]; then
    cp "$SRC" "$DEST"
  fi
}

set_memory_key() {
  local file="$1"
  local gib="$2"
  python3 - "$file" "$gib" <<'PY'
import pathlib, re, sys
path, gib = sys.argv[1], sys.argv[2]
file = pathlib.Path(path)
text = file.read_text()
new, count = re.subn(r"(?m)^memory:\s*\d+(?:\.\d+)?\s*$", f"memory: {gib}", text, count=1)
if count != 1:
    sys.exit(f"memory: line not found in {path}")
file.write_text(new)
PY
}

cmd_up() {
  require_colima
  ensure_profile_file
  if profile_running; then
    echo "Colima profile ${PROFILE} is already running."
  else
    colima start --profile "$PROFILE"
  fi
  cmd_status
}

cmd_down() {
  require_colima
  if profile_running; then
    colima stop --profile "$PROFILE"
  fi
  echo "Cluster is stopped. Its RAM reservation is back with macOS. Ollama is unchanged."
}

publish_local_context() {
  # Colima always writes the profile name (colima-ai). Lens should see "local".
  python3 - "$COLIMA_CONTEXT" "$CONTEXT" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

src, dst = sys.argv[1], sys.argv[2]
raw = subprocess.check_output(["kubectl", "config", "view", "--raw", "-o", "json"])
cfg = json.loads(raw)

def split(items):
    source = None
    kept = []
    for item in items or []:
        name = item.get("name")
        if name == src:
            source = item
        elif name == dst:
            continue
        else:
            kept.append(item)
    return source, kept

contexts = cfg.get("contexts") or []
names = [item.get("name") for item in contexts]
if src not in names and dst in names:
    cfg["current-context"] = dst
elif src in names:
    cluster, clusters = split(cfg.get("clusters"))
    user, users = split(cfg.get("users"))
    context, contexts = split(contexts)
    if not cluster or not user or not context:
        sys.exit(f"kubeconfig entry {src} is incomplete")
    cluster["name"] = dst
    user["name"] = dst
    context["name"] = dst
    context.setdefault("context", {})["cluster"] = dst
    context["context"]["user"] = dst
    cfg["clusters"] = clusters + [cluster]
    cfg["users"] = users + [user]
    cfg["contexts"] = contexts + [context]
    cfg["current-context"] = dst
else:
    sys.exit(f"kubeconfig has no {src} or {dst} context yet")

cfg["apiVersion"] = cfg.get("apiVersion") or "v1"
cfg["kind"] = cfg.get("kind") or "Config"
path = Path.home() / ".kube" / "config"
path.parent.mkdir(mode=0o700, exist_ok=True)
path.write_text(json.dumps(cfg, indent=2) + "\n")
os.chmod(path, 0o600)
print(f"kubeconfig cluster and context are {dst}")
PY
}

# 127.0.0.1:6443 on this Mac belongs to another SSH tunnel. k3s still listens on
# 6443 inside the guest. Forward that to 6445 and point the local context there.
ensure_api_forward() {
  local ssh_config="${HOME}/.colima/_lima/colima-${PROFILE}/ssh.config"
  local host="lima-colima-${PROFILE}"
  if [[ ! -f "$ssh_config" ]]; then
    return 0
  fi
  if ! lsof -nP -iTCP:6445 -sTCP:LISTEN >/dev/null 2>&1; then
    ssh -F "$ssh_config" -f -N -o ExitOnForwardFailure=yes \
      -L 127.0.0.1:6445:127.0.0.1:6443 "$host"
  fi
  python3 - "$CONTEXT" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
name, = sys.argv[1:]
cfg = json.loads(subprocess.check_output(["kubectl", "config", "view", "--raw", "-o", "json"]))
changed = False
for cluster in cfg.get("clusters") or []:
    if cluster.get("name") == name:
        server = "https://127.0.0.1:6445"
        if cluster.get("cluster", {}).get("server") != server:
            cluster.setdefault("cluster", {})["server"] = server
            changed = True
if not changed:
    sys.exit(0)
path = Path.home() / ".kube" / "config"
path.write_text(json.dumps(cfg, indent=2) + "\n")
os.chmod(path, 0o600)
PY
}

cmd_status() {
  require_colima
  colima status --profile "$PROFILE" || true
  echo
  if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$COLIMA_CONTEXT"; then
    publish_local_context
  fi
  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CONTEXT"; then
    echo "kubectl context ${CONTEXT} is not ready yet."
    return 0
  fi
  ensure_api_forward
  kubectl --context "$CONTEXT" get nodes
  echo
  kubectl --context "$CONTEXT" get pods -A
}

cmd_memory() {
  local gib="${MEMORY:-}"
  if [[ ! "$gib" =~ ^[0-9]+$ ]]; then
    echo "Usage: make cluster-memory MEMORY=25" >&2
    exit 2
  fi
  if (( gib < 4 || gib > 32 )); then
    echo "MEMORY must be from 4 to 32 GiB." >&2
    exit 2
  fi
  if (( gib > 28 )); then
    echo "Note: ${gib} GiB plus the loaded Qwen model leaves little RAM for macOS."
  fi

  require_colima
  set_memory_key "$SRC" "$gib"
  if [[ -f "$DEST" ]]; then
    set_memory_key "$DEST" "$gib"
  else
    ensure_profile_file
  fi

  if profile_running; then
    echo "Stopping the cluster to apply ${gib} GiB..."
    colima stop --profile "$PROFILE"
  fi
  colima start --profile "$PROFILE" --memory "$gib"
  echo "Cluster memory is ${gib} GiB. Data is kept. Put it back with: make cluster-memory MEMORY=25"
  cmd_status
}

usage() {
  echo "usage: $0 {up|down|status|memory}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
case "$1" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  memory) cmd_memory ;;
  *) usage ;;
esac
