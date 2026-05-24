# Vault Initialization - Step by Step

This document breaks down every single action taken during Vault initialization, in very small, digestible chunks.

---

## Overview

**Goal**: Set up Vault in Kubernetes with secure token storage

**What happens**: A background job runs after Vault starts, performing initialization tasks in order.

---

## Step 0: Prerequisites

**What this does**:
- Checks that Kubernetes is running
- Checks that Helm is installed
- Checks that kubectl can access the cluster

**Why**: These are required tools - if any are missing, we can't proceed.

---

## Step 1: Create Namespace

**What this does**:
```bash
kubectl create namespace devops-tools --dry-run=client -o yaml | kubectl apply -f -
```

**Why**:
- Keeps Vault in its own isolated namespace
- Prevents namespace conflicts with other apps

**What it creates**:
- Namespace called `devops-tools`
- Nothing else - just the namespace itself

---

## Step 2: Start the Vault Pod

**What this does**:
```bash
helm upgrade --install vault ./helm --namespace devops-tools -f ./helm/values.yaml
```

**Why**:
- Deploys Vault to the cluster
- Runs Vault as a StatefulSet (so it gets a stable hostname)

**What happens**:
1. Vault image is pulled from Docker registry
2. Vault pod starts running
3. Vault listens on port 8200

---

## Step 3: Wait for Vault to Start

**What this does**:
The job script repeatedly checks if Vault is ready:
```bash
vault status
```

**Why**:
- Vault takes a few seconds to start
- We can't proceed until it's running

**What checks**:
- Is Vault responding?
- Is it in "sealed" state (not initialized yet)?

---

## Step 4: Check if Already Initialized

**What this does**:
```bash
vault status
```

**Why**:
- If Vault was initialized before, we don't want to do it again
- This prevents overwriting existing data

**What checks**:
- Does Vault have a root token?
- Are there unseal keys stored?

**If already initialized**: Skip to Step 6

---

## Step 5: Initialize Vault (NEW Vault)

**What this does**:
```bash
vault init -shamir -n=5 -t=1
```

**Why**:
- Creates a brand new Vault instance
- Generates recovery keys and root token

**What it creates**:
- 5 unseal keys (for redundancy)
- 1 recovery key (for emergency recovery)
- 1 root token (superuser access)
- Encryption key for token storage

**Output (example)**:
```
Unseal Key 1: 6Gz...
Unseal Key 2: LkQ...
Unseal Key 3: xPm...
Unseal Key 4: bHn...
Unseal Key 5: jKw...
Recovery Key 1: 4rD...
Root Token: hvs.root...
```

**Important**: Write down these keys! You'll need them if Vault gets sealed.

---

## Step 6: Wait for Pod to Start Running

**What this does**:
```bash
kubectl wait --for=condition=ready pod -l app=vault -n devops-tools
```

**Why**:
- Makes sure Vault is actually running before we continue
- Prevents errors if the pod takes time to start

---

## Step 7: Store Unseal Keys

**What this does**:
```bash
kubectl create secret generic vault-unseal-keys \
  --from-literal=key1="$UNSEAL_KEY_1" \
  --from-literal=key2="$UNSEAL_KEY_2" \
  --from-literal=key3="$UNSEAL_KEY_3" \
  --from-literal=key4="$UNSEAL_KEY_4" \
  --from-literal=key5="$UNSEAL_KEY_5" \
  --from-literal=recovery-key="$RECOVERY_KEY" \
  --namespace devops-tools
```

**Why**:
- Backs up unseal keys in Kubernetes Secret
- Allows future unsealing if needed

**What it creates**:
- Secret named `vault-unseal-keys`
- Contains all 5 unseal keys and the recovery key

**Why not just use the init output?**
- The output is ephemeral - if you close your terminal, you lose it
- Secret is stored permanently in the cluster
- Anyone with cluster access can read the Secret

---

## Step 8: Save Root Token

**What this does**:
```bash
echo "$ROOT_TOKEN" | base64
```

**Why**:
- Base64 encoding is reversible
- We need this to store the token in the Secret

**What it creates**:
- A base64-encoded string of the root token
- Example: `aHR2cy5yb290Lm9hdXRo...`

---

## Step 9: Create Token Storage Secret

**What this does**:
```bash
kubectl create secret generic vault-tokens \
  --from-literal=root-token-encrypted="$ENCODED_ROOT_TOKEN" \
  --from-literal=service-token="" \
  --from-literal=k8s-token="" \
  --namespace devops-tools
```

**Why**:
- Stores the root token in Kubernetes Secret
- Creates space for future tokens (service, k8s auth, etc.)

**What it creates**:
- Secret named `vault-tokens`
- Base64-encoded root token stored in `root-token-encrypted` field

**Important**: This token is currently PLAINTEXT in the Secret. This is temporary and will be encrypted in the next step.

---

## Step 10: Enable Transit Engine

**What this does**:
```bash
vault secrets enable transit
```

**Why**:
- Enables encryption/decryption capabilities
- Allows us to encrypt tokens securely

**What it creates**:
- A "transit" secret engine
- A key called "vault-token-encryption"

**What it provides**:
- `transit/encrypt/secret` - encrypt a secret
- `transit/decrypt/secret` - decrypt a secret
- AES-256-GCM encryption

---

## Step 11: Encrypt Root Token

**What this does**:
```bash
vault write -field=ciphertext \
  transit/encrypt/secret \
  context="root-token" \
  key_name="vault-token-encryption" \
  plaintext=$(echo "$ROOT_TOKEN" | base64)
```

**Why**:
- Protects the root token from being read as plaintext
- Only decrypted values are useful

**What it creates**:
- An encrypted blob (ciphertext) containing the root token

**What it does**:
1. Takes the base64-encoded root token
2. Encrypts it using AES-256-GCM
3. Returns only the encrypted result (no plaintext!)

**Example output**:
```
ciphertext: gAAAAABk... (encrypted blob)
```

---

## Step 12: Update Token Secret with Encrypted Token

**What this does**:
```bash
kubectl create secret generic vault-tokens \
  --from-literal=root-token-encrypted="$ENCRYPTED_TOKEN" \
  --from-literal=service-token="" \
  --from-literal=k8s-token="" \
  --namespace devops-tools \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Why**:
- Updates the Secret with the encrypted token
- Now the Secret only contains encrypted blobs

**What it does**:
- Overwrites the plaintext root token with the encrypted version
- No plaintext tokens are stored

---

## Step 13: Create Kubernetes Auth Method

**What this does**:
```bash
vault auth enable kubernetes
```

**Why**:
- Allows Kubernetes pods to authenticate to Vault
- Uses Kubernetes service accounts as credentials

**What it creates**:
- A Kubernetes auth method
- Configuration endpoint at `auth/kubernetes`

---

## Step 14: Configure Kubernetes Auth Method

**What this does**:
```bash
vault write auth/kubernetes/config \
  token_reviewer_jwt="$KUBERNETES_SERVICE_ACCOUNT_JWT" \
  k8s_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT" \
  k8s_ca_cert="$KUBERNETES_CA_CERT"
```

**Why**:
- Tells Vault how to talk to the Kubernetes API
- Enables token review in the cluster

**What it configures**:
- JWT to use for token review
- Kubernetes API endpoint
- CA certificate for TLS

**What the JWT is**:
- A service account token from the Vault pod's service account
- Validated by the Kubernetes API server

---

## Step 15: Create Vault-Init Role

**What this does**:
```bash
vault write auth/kubernetes/role/vault-init \
  bound_service_account_names=vault \
  bound_service_account_namespaces=devops-tools \
  policies=vault-init-policy \
  ttl=1h
```

**Why**:
- Creates a role that allows Vault pods to authenticate
- Limits which pods can use this auth method

**What it creates**:
- Role called `vault-init`
- Applies the `vault-init-policy` to these requests
- Tokens expire after 1 hour

**Policies**:
- `vault-init-policy` - permissions for initialization

---

## Step 16: Create Vault-Init Policy

**What this does**:
```bash
vault policy write vault-init-policy - <<EOF
path "sys/leader" {
  capabilities = ["read"]
}
path "sys/health" {
  capabilities = ["read"]
}
path "sys/renew/*" {
  capabilities = ["update"]
}
path "auth/kubernetes/login" {
  capabilities = ["create", "update"]
}
path "sys/init" {
  capabilities = ["read", "update"]
}
path "sys/rekey/*" {
  capabilities = ["update"]
}
path "sys/leader" {
  capabilities = ["read"]
}
EOF
```

**Why**:
- Defines what the Vault pod can do during initialization
- Keeps permissions minimal

**What permissions are granted**:
- Read health status
- Read leader status
- Renew tokens
- Login via Kubernetes auth
- Rekey (if needed)
- Initialize Vault (if not already)

**What it doesn't allow**:
- Reading secrets
- Writing data
- User management
- Root access

---

## Step 17: Create Tunnel Role

**What this does**:
```bash
vault write auth/kubernetes/role/tunnel \
  bound_service_account_names=tunnel \
  bound_service_account_namespaces=devops-tools \
  policies=tunnel-policy \
  ttl=24h
```

**Why**:
- Creates a role for tunnel applications (e.g., cloudflared)
- Tokens last 24 hours (tunnel needs longer TTL)

**What it creates**:
- Role called `tunnel`
- Applies the `tunnel-policy` to these requests
- Tokens expire after 24 hours

---

## Step 18: Create Tunnel Policy

**What this does**:
```bash
vault policy write tunnel-policy - <<EOF
path "secret/tunnel" {
  capabilities = ["read"]
}
path "sys/renew/*" {
  capabilities = ["update"]
}
EOF
```

**Why**:
- Defines what tunnel apps can do
- Can read tunnel-related secrets
- Can renew their own tokens

**What permissions are granted**:
- Read secrets from `secret/tunnel`
- Renew their own tokens

**What it doesn't allow**:
- Creating secrets
- Reading other secrets
- System access

---

## Step 19: Create Kubernetes Operator Role

**What this does**:
```bash
vault write auth/kubernetes/role/k8s-operator \
  bound_service_account_names=operator \
  bound_service_account_namespaces=devops-tools \
  policies=k8s-policy \
  ttl=24h
```

**Why**:
- Creates a role for operator applications
- Tokens last 24 hours

**What it creates**:
- Role called `k8s-operator`
- Applies the `k8s-policy` to these requests
- Tokens expire after 24 hours

---

## Step 20: Create Kubernetes Policy

**What this does**:
```bash
vault policy write k8s-policy - <<EOF
path "sys/policies/*" {
  capabilities = ["read"]
}
path "sys/leases/*" {
  capabilities = ["create", "update", "renew", "revoke", "cancel", "lookup", "delete"]
}
path "sys/auth/*" {
  capabilities = ["read", "update"]
}
path "sys/audit/*" {
  capabilities = ["read", "update"]
}
path "sys/wrapping/*" {
  capabilities = ["create", "update", "wrap", "unwrap"]
}
path "auth/kubernetes/login" {
  capabilities = ["create", "update"]
}
EOF
```

**Why**:
- Defines what k8s-operator apps can do
- General Kubernetes operations

**What permissions are granted**:
- Read policies
- Manage leases (renew, revoke)
- Read/write auth configuration
- Read/write audit configuration
- Create and unwrap wrappings
- Kubernetes login

---

## Step 21: Create Encrypted Tunnel Token

**What this does**:
```bash
# This is done in a separate step because it requires user input
# The user generates a token, then we encrypt it
```

**Why**:
- Tunnel applications need their own token
- Generated by a user (not Vault initialization)
- Encrypted for security

**What happens**:
1. User generates a token with specific policies
2. Token is encrypted using Transit Engine
3. Encrypted token is stored in Secret

---

## Step 22: Create Cleanup Job (for testing)

**What this does**:
```bash
kubectl create job vault-cleanup --from=batch/vault-cleanup-job -n devops-tools
```

**Why**:
- For testing - removes everything created
- Safe to run multiple times

**What it removes**:
- Policies (vault-init-policy, tunnel-policy, k8s-policy)
- Roles (vault-init, tunnel, k8s-operator)
- Secrets (secret/tunnel, secret/tokens)
- Auth methods

---

## Summary

**Total steps**: 22
**Main phases**:
1. Setup (Steps 1-3)
2. Initialization (Steps 4-12)
3. Authentication setup (Steps 13-20)
4. Cleanup (Step 22)

**Security features**:
- Unseal keys stored in Secret
- Root token encrypted using Transit Engine
- Minimal permissions via policies
- Kubernetes RBAC integration

**Idempotency**:
- Steps 4-6 check if Vault is already initialized
- If already initialized, skips initialization
- Same `install.sh` script can be run multiple times safely