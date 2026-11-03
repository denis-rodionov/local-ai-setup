#!/bin/sh
set -eu

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
export PATH

cd "$(dirname "$0")"
namespace=image-arch-webhook

kubectl --context local apply -f webhook.yaml
kubectl --context local create configmap "$namespace" \
  --namespace "$namespace" \
  --from-file=webhook.py=webhook.py \
  --dry-run=client -o yaml | kubectl --context local apply -f -
kubectl --context local rollout restart deployment/"$namespace" --namespace "$namespace"

kubectl --context local wait --namespace "$namespace" \
  --for=condition=Ready certificate/"$namespace" --timeout=180s
kubectl --context local rollout status deployment/"$namespace" \
  --namespace "$namespace" --timeout=180s

i=0
while [ "$i" -lt 30 ]; do
  bundle=$(kubectl --context local get mutatingwebhookconfiguration "$namespace" \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)
  if [ -n "$bundle" ]; then
    echo "webhook is ready"
    exit 0
  fi
  i=$((i + 1))
  sleep 2
done
echo "webhook certificate was not injected" >&2
exit 1
