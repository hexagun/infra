# Vault Initialization Plan

## Goal
Initialize Vault, unseal it, and make tokens available for:
- Root token (bootstrap)
- Service tokens (for applications like cloudflared tunnel)
- K8s auth method tokens (for Kubernetes integration)

## Overview
This plan will:
1. Use the Vault Helm chart's built-in initialization feature
2. Create a post-install job to unseal Vault and save tokens
3. Store unseal keys and tokens in Kubernetes Secrets
4. Set up K8s auth method
5. External Secret Operator integration will be a separate step

## Prerequisites
- kubectl configured
- Helm 3.x
- Vault Helm chart: 0.27.0

## Step-by-Step Plan

### Step 1: Update Vault Values for Initialization
**File**: `helm/values.yaml`

Add Vault initialization configuration:
```yaml
vault:
  server:
    install: true  # Initialize Vault on first run
    initRequestParams:
      secret_shares: 5
      secret_threshold: 3
    standalone: true
    standaloneStorage:
      enabled: true
      storageClass: longhorn
      size: 10Gi
```

### Step 2: Create Post-Install Job
**File**: `helm/templates/vault-post-install-job.yaml`

This job will:
- Check if Vault is already initialized (idempotent)
- Check if Vault is already unsealed
- Only initialize/unseal if needed
- Use Vault Transit Engine to encrypt tokens before storing
- Configure K8s auth method
- Store encrypted tokens and unseal keys in Kubernetes Secrets

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-init
  namespace: devops-tools
  labels:
    app: vault
    component: post-install
spec:
  template:
    spec:
      serviceAccountName: vault-init-sa
      containers:
      - name: vault-init
        image: hashicorp/vault:1.15.2
        command:
          - /bin/sh
          - -c
          - |
            set -e

            VAULT_ADDR="http://127.0.0.1:8200"
            export VAULT_ADDR

            # Wait for Vault to be ready
            echo "Waiting for Vault..."
            until vault status >/dev/null 2>&1; do
              sleep 2
            done

            # Check if already initialized
            if vault status >/dev/null 2>&1; then
              VAULT_STATUS=$(vault status -address=$VAULT_ADDR -format=json)
              IS_INITIALIZED=$(echo $VAULT_STATUS | jq -r '.initialized')
              IS_SEALED=$(echo $VAULT_STATUS | jq -r '.sealed')

              echo "Vault already initialized (initialized=$IS_INITIALIZED, sealed=$IS_SEALED)"

              if [ "$IS_SEALED" = "true" ]; then
                # Check if we have unseal keys stored
                if [ -f /etc/vault/secrets/unseal-keys ]; then
                  echo "Unsealing Vault with stored keys..."
                  while IFS= read -r line; do
                    vault operator unseal -address=$VAULT_ADDR "$line"
                  done < /etc/vault/secrets/unseal-keys
                  echo "Vault unsealed!"
                else
                  echo "WARNING: Vault is sealed but no unseal keys found!"
                  echo "This job cannot unseal. Manual intervention required."
                  exit 1
                fi
              fi

              # Check if tokens already exist
              if vault kv get -field=root-token secret/tokens >/dev/null 2>&1; then
                echo "Tokens already exist. Skipping initialization."
                exit 0
              fi
            fi

            # Initialize Vault if needed
            if [ "$IS_INITIALIZED" != "true" ]; then
              echo "Initializing Vault..."
              vault init -address=$VAULT_ADDR -format=json > /tmp/init-result.json

              # Save unseal keys
              UNSEAL_KEYS=$(jq -r '.unseal_keys_b64[]' /tmp/init-result.json | tr '\n' ',' | sed 's/,$//')
              echo "$UNSEAL_KEYS" > /etc/vault/secrets/unseal-keys
              chmod 600 /etc/vault/secrets/unseal-keys

              # Extract and encrypt root token using Transit Engine
              ROOT_TOKEN=$(jq -r '.root_token' /tmp/init-result.json)

              # Enable Transit Engine
              vault audit enable file file_path=/var/log/vault-audit.log
              vault secrets enable -path=transit transit

              # Encrypt and save the root token
              ENCRYPTED_TOKEN=$(vault write -field=plaintext \
                -address=$VAULT_ADDR transit/encrypt/secret \
                plaintext="$ROOT_TOKEN" \
                context="vault-root-token" \
                key_name="vault-token-encryption")

              echo "$ENCRYPTED_TOKEN" > /tmp/root-token-encrypted.txt
              chmod 600 /tmp/root-token-encrypted.txt
            else
              # Get the encrypted root token from existing storage
              ENCRYPTED_TOKEN=$(vault kv get -field=root-token-encrypted secret/tokens 2>/dev/null || echo "")
            fi

            # Create service token for tunnel (encrypted)
            echo "Creating tunnel service token..."
            TUNNEL_TOKEN=$(vault token create -period=30d -policy=tunnel-policy -format=json | jq -r '.auth.client_token')

            ENCRYPTED_TUNNEL_TOKEN=$(vault write -field=plaintext \
              -address=$VAULT_ADDR transit/encrypt/secret \
              plaintext="$TUNNEL_TOKEN" \
              context="tunnel-token" \
              key_name="vault-token-encryption")

            # Create K8s auth method token (encrypted)
            echo "Creating K8s auth token..."
            K8S_TOKEN=$(vault token create -period=90d -policy=k8s-policy -format=json | jq -r '.auth.client_token')

            ENCRYPTED_K8S_TOKEN=$(vault write -field=plaintext \
              -address=$VAULT_ADDR transit/encrypt/secret \
              plaintext="$K8S_TOKEN" \
              context="k8s-token" \
              key_name="vault-token-encryption")

            # Create policies
            echo "Creating policies..."
            vault write -f sys/policy/vault-init-policy \
              policy='path "sys/*" { capabilities = ["read", "list"] } path "auth/token/renew" { capabilities = ["update"] }' \
              -address=$VAULT_ADDR

            vault write -f sys/policy/tunnel-policy \
              policy='path "secret/data/tunnel" { capabilities = ["read", "list", "create", "update", "delete"] }' \
              -address=$VAULT_ADDR

            vault write -f sys/policy/k8s-policy \
              policy='path "secret/data/*" { capabilities = ["read", "list"] }' \
              -address=$VAULT_ADDR

            # Create K8s auth method
            echo "Configuring K8s auth..."
            vault auth enable kubernetes -address=$VAULT_ADDR \
              -config=/etc/kubernetes/secrets/kubernetes-config

            # Configure K8s auth
            KUBERNETES_SERVICE_HOST=$(hostname -i)
            KUBERNETES_SERVICE_PORT="443"
            KUBERNETES_PORT="443"

            vault write auth/kubernetes/config \
              kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT" \
              token_reviewer_jwt="$(cat /etc/kubernetes/secrets/kubernetes-service-account-token)" \
              kubernetes_ca_cert="$(cat /etc/kubernetes/secrets/kubernetes-ca-cert)" \
              -address=$VAULT_ADDR

            # Create roles
            vault write auth/kubernetes/role/vault-init \
              bound_service_account_names=vault-init-sa \
              bound_service_account_namespaces=devops-tools \
              policies=vault-init-policy \
              ttl=24h \
              -address=$VAULT_ADDR

            vault write auth/kubernetes/role/tunnel \
              bound_service_account_names=cloudflared \
              bound_service_account_namespaces=devops-tools \
              policies=tunnel-policy \
              ttl=30d \
              -address=$VAULT_ADDR

            vault write auth/kubernetes/role/k8s-operator \
              bound_service_account_names=k8s-operator \
              bound_service_account_namespaces=devops-tools \
              policies=k8s-policy \
              ttl=90d \
              -address=$VAULT_ADDR

            # Encrypt and save all tokens to secret
            vault kv put secret/tokens \
              root-token-encrypted="$(cat /tmp/root-token-encrypted.txt | tr -d '\n')" \
              unseal-keys="$(cat /etc/vault/secrets/unseal-keys | tr -d '\n')" \
              tunnel-token-encrypted="$ENCRYPTED_TUNNEL_TOKEN" \
              k8s-token-encrypted="$ENCRYPTED_K8S_TOKEN" \
              -address=$VAULT_ADDR

            echo "Vault initialization complete!"

            # Exit 0 to indicate success
            exit 0
        env:
          - name: VAULT_ADDR
            value: http://127.0.0.1:8200
          - name: VAULT_SKIP_VERIFY
            value: "true"
        volumeMounts:
          - name: kube-config
            mountPath: /etc/kubernetes/secrets
          - name: tokens
            mountPath: /tmp
      restartPolicy: Never
      volumes:
        - name: kube-config
          secret:
            secretName: vault-kube-config
            defaultMode: 0600
        - name: tokens
          emptyDir: {}
      serviceAccountName: vault-init-sa
```

### Step 3: Create Service Account for Post-Install Job
**File**: `helm/templates/vault-init-serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-init-sa
  namespace: devops-tools
automountServiceAccountToken: true
```

### Step 4: Create Role Binding
**File**: `helm/templates/vault-init-rolebinding.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vault-init-sa
  namespace: devops-tools
subjects:
  - kind: ServiceAccount
    name: vault-init-sa
    namespace: devops-tools
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
```

### Step 5: Create Secret for Kubernetes Config
**File**: `helm/templates/vault-kube-config-secret.yaml`

This secret needs to contain:
- `kubernetes-config`: The kubeconfig for the cluster
- `kubernetes-service-account-token`: The service account token
- `kubernetes-ca-cert`: The CA certificate

For testing, you can create this manually:
```bash
kubectl create secret generic vault-kube-config \
  --from-file=kubernetes-config=/path/to/kubeconfig \
  --from-file=kubernetes-service-account-token=<token> \
  --from-file=kubernetes-ca-cert=<cert> \
  -n devops-tools
```

### Step 6: Create Token Decryption Helper
**File**: `helm/templates/vault-token-decryptor.yaml`

This helper allows decryption of tokens stored in Transit Engine:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-token-decryptor
  namespace: devops-tools
spec:
  template:
    spec:
      serviceAccountName: vault-init-sa
      containers:
      - name: vault-decrypt
        image: hashicorp/vault:1.15.2
        command:
          - /bin/sh
          - -c
          - |
            set -e

            VAULT_ADDR="http://127.0.0.1:8200"
            export VAULT_ADDR

            # Wait for Vault
            until vault status >/dev/null 2>&1; do
              sleep 2
            done

            # Enable Transit if not enabled
            if ! vault secrets list -address=$VAULT_ADDR | grep -q transit; then
              vault secrets enable transit -address=$VAULT_ADDR
            fi

            # Read encrypted token from Vault
            ENCRYPTED_TOKEN=$(vault kv get -field=tunnel-token-encrypted secret/tokens 2>/dev/null || echo "")
            if [ -z "$ENCRYPTED_TOKEN" ]; then
              echo "No encrypted token found"
              exit 1
            fi

            # Decrypt token
            DECRYPTED_TOKEN=$(vault write -field=ciphertext \
              -address=$VAULT_ADDR transit/decrypt/secret \
              ciphertext="$ENCRYPTED_TOKEN" \
              context="tunnel-token" \
              key_name="vault-token-encryption" \
              | jq -r '.ciphertext')

            # Save decrypted token to file for mounting
            echo "$DECRYPTED_TOKEN" > /tmp/tunnel-token.txt
            echo "Decrypted tunnel token saved to /tmp/tunnel-token.txt"
            exit 0
        env:
          - name: VAULT_ADDR
            value: http://127.0.0.1:8200
          - name: VAULT_SKIP_VERIFY
            value: "true"
        volumeMounts:
          - name: tokens
            mountPath: /tmp
      restartPolicy: Never
      volumes:
        - name: tokens
          emptyDir: {}
```

### Step 7: Create Cleanup Job (for testing)
**File**: `helm/templates/vault-cleanup-job.yaml`

For testing purposes, to revert the installation:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-cleanup
  namespace: devops-tools
spec:
  template:
    spec:
      serviceAccountName: vault-init-sa
      containers:
      - name: vault-cleanup
        image: hashicorp/vault:1.15.2
        command:
          - /bin/sh
          - -c
          - |
            set -e

            VAULT_ADDR="http://127.0.0.1:8200"
            export VAULT_ADDR

            # Delete policies
            vault delete sys/policy/vault-init-policy 2>/dev/null || true
            vault delete sys/policy/tunnel-policy 2>/dev/null || true
            vault delete sys/policy/k8s-policy 2>/dev/null || true

            # Delete roles
            vault delete auth/kubernetes/role/vault-init 2>/dev/null || true
            vault delete auth/kubernetes/role/tunnel 2>/dev/null || true
            vault delete auth/kubernetes/role/k8s-operator 2>/dev/null || true

            # Delete secrets
            vault kv delete secret/tunnel 2>/dev/null || true
            vault kv delete secret/tokens 2>/dev/null || true

            echo "Vault cleanup complete"
        env:
          - name: VAULT_ADDR
            value: http://127.0.0.1:8200
          - name: VAULT_SKIP_VERIFY
            value: "true"
      restartPolicy: Never
```

## Execution Steps

### For Testing (Rollbackable):
```bash
# 1. Run the installation script
./scripts/install.sh

# 2. Verify Vault is initialized and unsealed
kubectl exec -n devops-tools $(kubectl get pods -n devops-tools -l app=vault -o jsonpath='{.items[0].metadata.name}') -- vault status

# 3. Check tokens Secret
kubectl get secret vault-tokens -n devops-tools -o jsonpath='{.data}'

# 4. Revert by running cleanup job
kubectl apply -f helm/templates/vault-cleanup-job.yaml
kubectl create job vault-cleanup --from=batch/vault-cleanup
```

### For Production:
```bash
# Run installation (no cleanup needed)
./scripts/install.sh

# Export tokens
kubectl get secret vault-tokens -n devops-tools -o jsonpath='{.data.root-token}' | base64 -d
kubectl get secret vault-tokens -n devops-tools -o jsonpath='{.data.service-token}' | base64 -d
```

## External Secret Operator (Future Step)
After Vault is working, set up ESO:
```bash
# Install ESO
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# Create an ExternalSecret for the tunnel token
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: tunnel-token
  namespace: devops-tools
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: SecretStore
  target:
    name: tunnel-token
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: secret/data/tunnel
        property: token
EOF
```

## Troubleshooting

### Vault not initializing
```bash
# Check Vault pod logs
kubectl logs -n devops-tools $(kubectl get pods -n devops-tools -l app=vault -o jsonpath='{.items[0].metadata.name}')
```

### Post-install job failing
```bash
# Check job status
kubectl describe job vault-init -n devops-tools

# Check job logs
kubectl logs -n devops-tools job/vault-init
```

### Need to manually unseal
```bash
# Enter Vault pod
kubectl exec -it -n devops-tools $(kubectl get pods -n devops-tools -l app=vault -o jsonpath='{.items[0].metadata.name}') -- bash

# Manually unseal with each key
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>
```

## Security Considerations

### Why Transit Engine for Token Encryption?
Storing plaintext tokens in Kubernetes Secrets is a security risk because:
- Anyone with cluster access can read and decode the Secret
- Tokens can be stolen and used to compromise Vault

Using Vault Transit Engine for encryption provides:
- **Vault-managed encryption keys** (managed by Vault itself)
- **Strong encryption** using AES-256-GCM
- **Audit trail** of all encryption/decryption operations
- **Key rotation** capabilities

### How Tokens Are Stored
1. Tokens are generated in Vault
2. They're encrypted using Vault's Transit Engine
3. Only encrypted blobs are stored in Kubernetes Secrets
4. To use a token, you decrypt it using the Transit Engine

### Using Decrypted Tokens
For applications like cloudflared, decrypt the token before use:

```bash
# Create a deployment that decrypts and uses the token
kubectl create job tunnel-token-decryptor --from=batch/vault-token-decryptor -n devops-tools

# Copy the token to the cloudflared deployment
TOKEN=$(kubectl get secret vault-tokens -n devops-tools -o jsonpath='{.data.tunnel-token-encrypted}')
# Then decrypt and mount
```

### Token Rotation
Tokens expire based on their TTL. To rotate:
1. Create a new token with required policies
2. Encrypt and store the new token
3. Update your application to use the new token
4. Delete old tokens from Vault

### Idempotency
The post-install job is designed to be idempotent:
- Checks if Vault is already initialized
- Checks if Vault is already unsealed
- Checks if tokens already exist
- Only performs actions that are needed

Running `./scripts/install.sh` multiple times will be safe.

## Notes
- The post-install job runs once and then completes
- Unseal keys are stored in a Secret for future use if needed
- Tokens have time limits (configurable) - renew them as needed
- For production, consider using Vault Enterprise or setting up HSM