#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="devops-tools"
RELEASE="infra"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_PATH="$SCRIPT_DIR/.."

echo "==> Deploying infrastructure"

# Always create namespaces (idempotent)
echo "==> Creating namespaces"
kubectl apply -f "$CHART_PATH/namespaces"

# Always install Longhorn (idempotent)
echo "==> Installing Longhorn"
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo update
helm upgrade --install longhorn longhorn/longhorn \
  -n longhorn-system \
  --create-namespace \
  -f "$CHART_PATH/helm/longhorn-values.yaml"

# Apply storage primitives (idempotent)
echo "==> Applying storage primitives"
kubectl apply -f "$CHART_PATH/storage/pvcs"

# Install/upgrade helm chart
echo "==> Installing Helm chart"
helm upgrade --install "$RELEASE" "$CHART_PATH/helm" \
  -n "$NAMESPACE" \
  --timeout 30m30s \
  --create-namespace

echo "Infra deployed to namespace: $NAMESPACE"
echo ""
echo "To check logs:"
echo "  kubectl logs -l job-name=vault-bootstrap -n $NAMESPACE"
echo "  kubectl get pods -n $NAMESPACE"
