# Infra Helm Chart

This is an umbrella chart for cluster infrastructure services including Jenkins and Vault.

## Overview

The chart provides:
- **Jenkins**: CI/CD server with k8s credentials binding
- **Vault**: Secrets management with Kubernetes auth method

## Prerequisites

- Kubernetes 1.21+
- Helm 3.0+
- StorageClass for persistent volumes (Longhorn)

## Installation

### Install all services

```bash
helm install infra .
```

### Install only specific services

```bash
# Only Jenkins
helm install infra .
 helm install infra --set jenkins.enabled=true --set vault.enabled=false

# Only Vault
helm install infra .
 helm install infra --set vault.enabled=true --set jenkins.enabled=false
```

## Configuration

### Jenkins

```yaml
jenkins:
  controller:
    serviceType: NodePort
    nodePort: 30263
    jenkinsUriPrefix: "/jenkins"
```

### Vault

```yaml
vault:
  server:
    ha:
      enabled: false
    dataStorage:
      enabled: true
      storageClass: longhorn
      size: 10Gi
  initJob:
    enabled: true
    image:
      repository: bitnami/kubectl
      tag: 1.28.0
```

## Services

### Jenkins
- Service: `infra-jenkins` on port 8080
- Ingress: `/jenkins` at `hex-a-gun.com`
- Persistent Volume: `jenkins-pvc-longhorn`

### Vault
- Service: `infra-vault` on port 8200
- API: `http://infra-vault:8200`
- UI: `http://infra-vault-ui:8201`
- Namespace: `devops-tools`

## Accessing Vault

1. Get the root token from the encrypted secret:
```bash
kubectl get secret vault-tokens -n devops-tools -o jsonpath={.data.root-token-encrypted} | base64 -d
```

2. Use the token to authenticate to Vault

## Vault Initialization

The post-install hook automatically:
1. Waits for Vault to be ready
2. Initializes Vault with Shamir keys (5 of 5)
3. Stores unseal keys and encrypted tokens in Kubernetes Secrets
4. Enables Transit Engine for token encryption
5. Configures Kubernetes auth method

See `VAULT-INIT-STEP-BY-STEP.md` for detailed initialization steps.