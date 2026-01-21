#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="devops-tools"
RELEASE="infra"
CHART_PATH="$(dirname "$0")/.."

echo "==> Creating namespaces"
kubectl apply -f "$CHART_PATH/namespaces"

# Longhorn Not well suited for umbrella chart

helm repo add longhorn https://charts.longhorn.io

helm repo update

helm upgrade --install longhorn longhorn/longhorn \
  -n longhorn-system \
  --create-namespace \
  -f "$CHART_PATH/helm/longhorn-values.yaml"

# Pull dependencies (jenkins + ingress-nginx)
helm dependency update "$CHART_PATH/helm"

echo "==> Applying storage primitives"
kubectl apply -f "$CHART_PATH/storage/pvcs"

# Install/upgrade release
helm upgrade --install "$RELEASE" "$CHART_PATH/helm" \
  -n "$NAMESPACE" \
  --timeout 30m30s \
  --create-namespace

echo "✅ Infra deployed to namespace: $NAMESPACE"