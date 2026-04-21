#!/usr/bin/env bash
set -euo pipefail

# Phases: vault, eso, cloudflared, jenkins, full
# Usage: PHASE=vault ./scripts/install.sh
PHASE="${PHASE:-full}"

NAMESPACE="devops-tools"
RELEASE="infra"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_PATH="$SCRIPT_DIR/.."

echo "==> Deploying in PHASE=$PHASE mode"

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

# Determine enable flags based on phase
case "$PHASE" in
  vault)
    JENKINS_ENABLED="false"
    VAULT_ENABLED="true"
    ESO_ENABLED="false"
    CLOUDFLARED_ENABLED="false"
    ;;
  eso)
    JENKINS_ENABLED="false"
    VAULT_ENABLED="true"
    ESO_ENABLED="true"
    CLOUDFLARED_ENABLED="false"
    ;;
  cloudflared)
    JENKINS_ENABLED="false"
    VAULT_ENABLED="true"
    ESO_ENABLED="true"
    CLOUDFLARED_ENABLED="true"
    ;;
  jenkins)
    JENKINS_ENABLED="true"
    VAULT_ENABLED="true"
    ESO_ENABLED="true"
    CLOUDFLARED_ENABLED="false"
    ;;
  full)
    JENKINS_ENABLED="true"
    VAULT_ENABLED="true"
    ESO_ENABLED="true"
    CLOUDFLARED_ENABLED="true"
    ;;
  *)
    echo "❌ Unknown PHASE: $PHASE"
    echo "Use: vault, eso, cloudflared, jenkins, or full"
    exit 1
    ;;
esac

# Install/upgrade helm chart with phase-specific overrides
echo "==> Installing Helm chart (jenkins=$JENKINS_ENABLED, vault=$VAULT_ENABLED, eso=$ESO_ENABLED, cloudflared=$CLOUDFLARED_ENABLED)"
helm upgrade --install "$RELEASE" "$CHART_PATH/helm" \
  -n "$NAMESPACE" \
  --timeout 30m30s \
  --create-namespace \
  --set jenkins.enabled="$JENKINS_ENABLED" \
  --set vault.enabled="$VAULT_ENABLED" \
  --set externalSecrets.install="$ESO_ENABLED" \
  --set cloudflared.enabled="$CLOUDFLARED_ENABLED"

echo "✅ Infra deployed to namespace: $NAMESPACE"
echo ""
echo "To check logs:"
echo "  kubectl logs -l job-name=vault-bootstrap -n $NAMESPACE"
echo "  kubectl get pods -n $NAMESPACE"
