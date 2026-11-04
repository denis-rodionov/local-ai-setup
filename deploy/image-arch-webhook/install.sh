#!/bin/sh
# Install cert-manager if this cluster does not have it, then the image webhook.
set -eu

PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
export PATH

cd "$(dirname "$0")"
namespace=image-arch-webhook
context=local
cert_manager_version=v1.18.2

kubectl --context "$context" get nodes >/dev/null

if ! kubectl --context "$context" get deploy -n cert-manager cert-manager >/dev/null 2>&1; then
  echo "Installing cert-manager ${cert_manager_version}"
  kubectl --context "$context" apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${cert_manager_version}/cert-manager.yaml"
fi

kubectl --context "$context" wait --namespace cert-manager \
  --for=condition=Available deployment --all --timeout=180s

i=0
while [ "$i" -lt 12 ]; do
  if kubectl --context "$context" apply -f webhook.yaml; then
    break
  fi
  i=$((i + 1))
  if [ "$i" -eq 12 ]; then
    echo "cert-manager did not accept the webhook manifests" >&2
    exit 1
  fi
  sleep 5
done

kubectl --context "$context" create configmap "$namespace" \
  --namespace "$namespace" \
  --from-file=webhook.py=webhook.py \
  --dry-run=client -o yaml | kubectl --context "$context" apply -f -
kubectl --context "$context" rollout restart deployment/"$namespace" --namespace "$namespace"

kubectl --context "$context" wait --namespace "$namespace" \
  --for=condition=Ready certificate/"$namespace" --timeout=180s
kubectl --context "$context" rollout status deployment/"$namespace" \
  --namespace "$namespace" --timeout=180s

i=0
while [ "$i" -lt 30 ]; do
  bundle=$(kubectl --context "$context" get mutatingwebhookconfiguration "$namespace" \
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
