#!/bin/sh
VAULT_ADDR="${VAULT_ADDR:-http://infra-vault:8200}"
BOOTSTRAP_SECRET="vault-bootstrap-secrets"

echo "===> Waiting for Vault..."
until curl -s "http://vault-0.vault-internal" > /dev/null 2>&1; do
  echo "Vault is not reachable yet (DNS or service starting)..."
  sleep 5
done

# Check initialization status
echo "===> Checking initialization status"
INIT_STATUS=$(vault operator init -status 2>/dev/null | grep -E "Initialized|Error" || true)
echo "$INIT_STATUS"

if echo "$INIT_STATUS" | grep -q "Initialized: true"; then
  echo "Vault is already initialized. Skipping init."
elif echo "$INIT_STATUS" | grep -q "Error"; then
  # Try to parse if it says already initialized
  if curl -s "$VAULT_ADDR/v1/sys/health?sealed" 2>/dev/null | grep -q '"initialized":true'; then
    echo "Vault already initialized (confirmed via API). Skipping init."
  else
    echo "Initializing Vault..."
    vault operator init \
      -address="$VAULT_ADDR" \
      -format=json \
      -key-shares=1 \
      -key-threshold=1 \
      > /tmp/vault-init.json

    # Extract root token and unseal key
    ROOT_TOKEN=$(cat /tmp/vault-init.json | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4)
    UNSEAL_KEY=$(cat /tmp/vault-init.json | grep -o '"unseal_keys_b64":\[[^]]*\]' | sed 's/unseal_keys_b64:\[//' | sed 's/\]//' | tr -d '"' | tr -d ' ')

    if [ -z "$ROOT_TOKEN" ] || [ -z "$UNSEAL_KEY" ]; then
      echo "ERROR: Failed to extract Vault credentials!"
      cat /tmp/vault-init.json
      exit 1
    fi

    echo "Vault initialized successfully!"

    # Store credentials in Kubernetes Secret
    kubectl create secret generic "$BOOTSTRAP_SECRET" \
      --from-literal=root-token="$ROOT_TOKEN" \
      --from-literal=unseal-key="$UNSEAL_KEY" \
      --dry-run=client -o yaml | kubectl apply -f -

    echo "Credentials stored in secret: $BOOTSTRAP_SECRET"
  fi
else
  echo "Initializing Vault..."
  vault operator init \
    -address="$VAULT_ADDR" \
    -format=json \
    -key-shares=1 \
    -key-threshold=1 \
    > /tmp/vault-init.json

  ROOT_TOKEN=$(cat /tmp/vault-init.json | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4)
  UNSEAL_KEY=$(cat /tmp/vault-init.json | grep -o '"unseal_keys_b64":\[[^]]*\]' | sed 's/unseal_keys_b64:\[//' | sed 's/\]//' | tr -d '"' | tr -d ' ')

  if [ -z "$ROOT_TOKEN" ] || [ -z "$UNSEAL_KEY" ]; then
    echo "ERROR: Failed to extract Vault credentials!"
    cat /tmp/vault-init.json
    exit 1
  fi

  echo "Vault initialized successfully!"

  # Store credentials in Kubernetes Secret
  kubectl create secret generic "$BOOTSTRAP_SECRET" \
    --from-literal=root-token="$ROOT_TOKEN" \
    --from-literal=unseal-key="$UNSEAL_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "Credentials stored in secret: $BOOTSTRAP_SECRET"
fi

# Unseal Vault if sealed
echo "===> Checking seal status"
SEAL_STATUS=$(vault operator seal-status 2>/dev/null | head -1 || true)
echo "$SEAL_STATUS"

if echo "$SEAL_STATUS" | grep -q "sealed"; then
  echo "Vault is sealed. Unsealing..."

  # Retrieve unseal key from secret
  UNSEAL_KEY=$(kubectl get secret "$BOOTSTRAP_SECRET" -o jsonpath='{.data.unseal-key}' | base64 -d)

  if [ -z "$UNSEAL_KEY" ]; then
    echo "ERROR: Could not retrieve unseal key!"
    exit 1
  fi

  vault operator unseal \
    -address="$VAULT_ADDR" \
    -key="$UNSEAL_KEY"

  echo "Vault unsealed!"
else
  echo "Vault is already unsealed."
fi

# Create a long-lived admin token
echo "===> Creating admin token"
ROOT_TOKEN=$(kubectl get secret "$BOOTSTRAP_SECRET" -o jsonpath='{.data.root-token}' | base64 -d)
export VAULT_TOKEN="$ROOT_TOKEN"

# Check if admin token already exists
ADMIN_TOKEN_EXISTS=$(vault token lookup -fields=accessor admin-token 2>/dev/null | grep -v "WARNING" || true)

if [ -z "$ADMIN_TOKEN_EXISTS" ]; then
  echo "Creating admin token with 90-day TTL..."
  ADMIN_TOKEN=$(vault token create \
    -format=json \
    -ttl=90h \
    -max-ttl=720h \
    -metadata=purpose=admin \
    -field=token)

  # Append admin token to secret
  kubectl patch secret "$BOOTSTRAP_SECRET" \
    --type=json \
    -p='[{"op": "add", "path": "data.admin-token", "value": "'"$(echo -n "$ADMIN_TOKEN" | base64 | tr -d '\n')"'"}]'

  echo "Admin token created and stored."
else
  echo "Admin token already exists."
fi

echo "===> Bootstrap complete"
echo "Vault is ready!"
echo ""
echo "To retrieve credentials:"
echo "  kubectl get secret vault-bootstrap-secrets -o yaml"
echo ""
echo "To verify Vault status:"
echo "  VAULT_ADDR=http://infra-vault:8200 vault status"
