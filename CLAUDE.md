# Infra Chart - Kubernetes Infrastructure

## Overview
This is an umbrella Helm chart for cluster infrastructure components, primarily focusing on Jenkins and HashiCorp Vault. The chart deploys to the `devops-tools` namespace and includes integration with Longhorn for persistent storage.

## Quick Start
```bash
# Run the installation script
./scripts/install.sh
```

## Components

### Jenkins
- **Chart**: jenkins:5.8.86 (from https://charts.jenkins.io)
- **Service**: NodePort (port 30263)
- **Ingress**: /jenkins path on host hex-a-gun.com
- **Persistence**: PVC using Longhorn storage (20Gi)
- **Service Account**: Created manually via templates
- **Agent Service Account**: Created manually via templates

### HashiCorp Vault
- **Chart**: vault:0.27.0 (from https://helm.releases.hashicorp.com)
- **HA Mode**: Disabled (single server)
- **Storage**: Longhorn, 10Gi volume
- **CSI Provider**: Included for Kubernetes integration
- **UI**: Enabled via NodePort
- **Ingress**: Configured

### Longhorn
- **Chart**: longhorn (https://charts.longhorn.io)
- **Namespace**: longhorn-system
- **Service**: NodePort (port 30080)
- **Note**: Installed separately by the install script (not bundled in the umbrella chart)

## Namespaces
The chart creates the following namespaces:
- dev
- staging
- prod
- devops-tools
- longhorn-system

## Storage
All persistent volumes use Longhorn storage class:
- Jenkins: 20Gi PVC (managed by umbrella chart)
- Vault: 10Gi PVC (managed by vault chart)
- Storage primitives: Applied via `storage/pvcs/` directory

## Configuration

### Customizing Jenkins
Edit `helm/values.yaml` to modify:
- NodePort port
- Ingress host/path
- PVC size and access mode
- Plugin list
- Resource limits

### Customizing Vault
Edit `helm/values.yaml` to modify:
- Storage size
- HA enabled/disabled
- Storage class

## Recent Changes
- **v0.5.0**: Updated dependencies (Jenkins 5.8.86, Vault 0.27.0)
- Vault installation added
- Jenkins migrated to Longhorn
- k3s migration completed

## Notes
- Longhorn is not included in the umbrella chart (installed separately)
- All commands are tested and optimized for Ubuntu environments
- Helm lock file is committed to ensure reproducible deployments