#!/bin/bash
# Install LiteLLM. The master key is read from .env and stored as a Secret.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="/opt/homebrew/bin:${HOME}/.local/bin:${PATH}"
CONTEXT=local

if [[ ! -f "$ROOT/.env" ]]; then
  echo "Missing $ROOT/.env. Copy .env.example and set LITELLM_MASTER_KEY." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  echo "LITELLM_MASTER_KEY is empty in .env" >&2
  exit 1
fi

if [[ -z "${LITELLM_DB_PASSWORD:-}" ]]; then
  LITELLM_DB_PASSWORD="$(openssl rand -hex 24)"
  printf 'LITELLM_DB_PASSWORD=%s\n' "$LITELLM_DB_PASSWORD" >> "$ROOT/.env"
fi

mkdir -p "${HOME}/.local-ai/litellm-postgres"

kubectl --context "$CONTEXT" apply -f "$ROOT/deploy/ai/namespace.yaml"
kubectl --context "$CONTEXT" apply -f "$ROOT/deploy/ai/ollama-bridge/bridge.yaml"
kubectl --context "$CONTEXT" -n ai rollout status deploy/ollama-bridge --timeout=180s
kubectl --context "$CONTEXT" -n ai create secret generic litellm \
  --from-literal=master_key="$LITELLM_MASTER_KEY" \
  --from-literal=db_password="$LITELLM_DB_PASSWORD" \
  --from-literal=database_url="postgresql://litellm:${LITELLM_DB_PASSWORD}@litellm-db:5432/litellm" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
kubectl --context "$CONTEXT" apply -f "$ROOT/deploy/ai/litellm-db.yaml"
kubectl --context "$CONTEXT" -n ai rollout status deploy/litellm-db --timeout=180s
kubectl --context "$CONTEXT" apply -f "$ROOT/deploy/ai/litellm.yaml" -f "$ROOT/deploy/ai/ingress.yaml"
kubectl --context "$CONTEXT" -n ai rollout status deploy/litellm --timeout=300s
