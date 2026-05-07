# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository manages infrastructure deployment for a Kubernetes cluster using Helm charts. The main chart deploys Jenkins and Vault, with a bootstrap process to initialize and unseal Vault on first deployment.

## Key Components

### Helm Chart Structure
- `helm/Chart.yaml`: Main chart definition with dependencies on Jenkins and Vault charts
- `helm/values.yaml`: Configuration values for Jenkins and Vault deployments
- `helm/templates/`: Template files for Kubernetes resources
  - `vault-bootstrap-job.yaml`: Bootstrap job that initializes and unseals Vault
  - `vault-bootstrap-configmap.yaml`: Contains the bootstrap script
  - `vault-bootstrap-rbac.yaml`: RBAC configuration for the bootstrap job
- `scripts/install.sh`: Deployment script that handles namespace creation, Longhorn installation, PVCs, and Helm chart deployment

### Vault Bootstrap Process
The vault bootstrap process is handled by a Helm hook that:
1. Initializes Vault with a single key share and threshold (for development purposes)
2. Stores the root token and unseal key in a Kubernetes secret
3. Unseals Vault using the stored key
4. Creates a long-lived admin token for operational access

### Jenkins Configuration
- Jenkins is configured with a NodePort service on port 30263
- Uses PVC for persistent storage
- Has a comprehensive list of plugins installed
- Includes ingress configuration for external access

## Deployment Process

1. Run `scripts/install.sh` to deploy the infrastructure
2. The script handles:
   - Creating namespaces
   - Installing Longhorn storage system
   - Applying PVCs
   - Installing the Helm chart with a 30-minute timeout

## Key Files and Their Purposes

- `helm/templates/vault-bootstrap-job.yaml`: Defines the bootstrap Job that runs post-install
- `helm/templates/vault-bootstrap-configmap.yaml`: Contains the shell script that performs Vault initialization
- `scripts/vault-bootstrap.sh`: Standalone script version of the bootstrap logic
- `scripts/install.sh`: Main deployment script for the entire infrastructure

## Development and Testing

To deploy the infrastructure:
```bash
./scripts/install.sh
```

To check the bootstrap job logs:
```bash
kubectl logs -l job-name=vault-bootstrap -n devops-tools
```

To verify Vault status:
```bash
kubectl get pods -n devops-tools
kubectl get secret vault-bootstrap-secrets -n devops-tools -o yaml
```

## Common Tasks

- Deploying the infrastructure: Run `./scripts/install.sh`
- Checking Vault bootstrap status: `kubectl logs -l job-name=vault-bootstrap -n devops-tools`
- Verifying Vault initialization: `kubectl get secret vault-bootstrap-secrets -n devops-tools -o yaml`
- Accessing Jenkins: Use the NodePort service at port 30263 or via ingress at hex-a-gun.com/jenkins