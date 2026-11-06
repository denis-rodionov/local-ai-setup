#!/bin/bash
# Install Open WebUI. Keys are read from .env and stored as a Secret.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="/opt/homebrew/bin:${HOME}/.local/bin:${PATH}"
CONTEXT=local
ENV_FILE="$ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy .env.example and set LITELLM_MASTER_KEY." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  echo "LITELLM_MASTER_KEY is empty in .env" >&2
  exit 1
fi

if [[ -z "${WEBUI_SECRET_KEY:-}" ]]; then
  WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
  printf 'WEBUI_SECRET_KEY=%s\n' "$WEBUI_SECRET_KEY" >> "$ENV_FILE"
fi

if [[ -z "${LITELLM_DB_PASSWORD:-}" ]]; then
  echo "LITELLM_DB_PASSWORD is empty. Run make litellm-install first." >&2
  exit 1
fi

mkdir -p "${HOME}/.local-ai/open-webui"

# Same Postgres server as LiteLLM, separate database. The schemas are not shared.
kubectl --context "$CONTEXT" -n ai exec deploy/litellm-db -- \
  sh -c 'psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "SELECT 1 FROM pg_database WHERE datname = '\''openwebui'\''"' \
  | grep -q 1 || kubectl --context "$CONTEXT" -n ai exec deploy/litellm-db -- \
  sh -c 'psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE openwebui"'

DB_PASSWORD_ENCODED="$(python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["LITELLM_DB_PASSWORD"], safe=""))')"

kubectl --context "$CONTEXT" apply -f "$ROOT/deploy/ai/namespace.yaml"
kubectl --context "$CONTEXT" -n ai create secret generic open-webui \
  --from-literal=openai_api_key="$LITELLM_MASTER_KEY" \
  --from-literal=webui_secret_key="$WEBUI_SECRET_KEY" \
  --from-literal=database_url="postgresql://litellm:${DB_PASSWORD_ENCODED}@litellm-db:5432/openwebui" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
kubectl --context "$CONTEXT" apply -f "$ROOT/deploy/ai/open-webui.yaml"
kubectl --context "$CONTEXT" -n ai rollout status deploy/open-webui --timeout=300s
