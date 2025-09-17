#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="devops-tools"
RELEASE="infra"
CHART_PATH="$(dirname "$0")/.."

# Ensure namespace exists
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

# Pull dependencies (jenkins + ingress-nginx)
helm dependency update "$CHART_PATH"

# Install/upgrade release
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  -n "$NAMESPACE" \
#   -f "$CHART_PATH/values/devops-tools.yaml"

echo "✅ Infra deployed to namespace: $NAMESPACE"