# Jottacloud Backup Container

Automated, secure backup of Jottacloud to Backblaze B2 using rclone and Kopia in Kubernetes.

## Features

- **Security First**: Non-root user, minimal Alpine base, signed container images
- **Multi-Architecture**: Supports amd64 and arm64
- **Monitoring**: Built-in healthchecks.io integration
- **Kubernetes Native**: CronJob-based scheduled backups

## How It Works

1. **rclone** downloads Jottacloud files to local storage
2. **Kopia** creates encrypted backups to Backblaze B2
3. **CronJob** runs on schedule (default: every 6 hours)

## Quick Start

### 1. Configure Storage & Settings

Edit `kubernetes/persistent-volumes.yaml` for your NFS server:

```yaml
nfs:
  server: 10.10.10.1 # Your NFS server
  path: "/tank/backup/jottacloud"
```

Edit `kubernetes/configmap.yaml` for your environment:

```yaml
# Update these values:
S3_ENDPOINT: "s3.us-west-000.backblazeb2.com" # Your B2 region
S3_BUCKET: "your-existing-kopia-bucket" # Your bucket name
```

Edit `kubernetes/cronjob.yaml` to adjust the schedule if needed (default: every 6 hours at :45 past).

### 2. Create Namespace

```bash
kubectl apply -f kubernetes/pod-security-policy.yaml
```

### 3. Create Secrets

```bash
# Create rclone config locally first
rclone config
# n) New remote
# name: jotta
# type: jottacloud
# auth type: standard (default)
# Generate a personal login token from:
#   Jottacloud web UI → Settings → Security → Personal Login Token
# Paste the token when prompted
# Non-default storage: y (to access Sync mountpoint)
# Device: Jotta (default)
# Mountpoint: Sync

# Verify it works
rclone lsd jotta:

# Create secret with all credentials
kubectl create secret generic jottacloud-backup-secrets \
  --namespace=jottacloud-backup \
  --from-file=RCLONE_CONFIG='$HOME/.config/rclone/rclone.conf' \
  --from-literal=S3_ACCESS_KEY='your-b2-key-id' \
  --from-literal=S3_SECRET_KEY='your-b2-app-key' \
  --from-literal=KOPIA_PASSWORD='your-repo-password' \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **Note:** Jottacloud tokens rotate aggressively and only one session can be active per config. Each container instance must use its own rclone config — do not share configs between machines. If the config PVC is lost, you will need to generate a new personal login token from the Jottacloud web UI and re-run `rclone config`.

### 4. Deploy

```bash
# Deploy storage, configuration, and CronJob
kubectl apply -f kubernetes/persistent-volumes.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/serviceaccount.yaml
kubectl apply -f kubernetes/network-policy.yaml
kubectl apply -f kubernetes/cronjob.yaml
```

## Configuration

### Required Secrets

| Variable         | Description                       |
| ---------------- | --------------------------------- |
| `RCLONE_CONFIG`  | Base64-encoded rclone config file |
| `S3_ACCESS_KEY`  | Backblaze B2 key ID               |
| `S3_SECRET_KEY`  | Backblaze B2 application key      |
| `KOPIA_PASSWORD` | Repository encryption password    |

### Update Secrets

```bash
# To update secrets (same command works for create/update)
kubectl create secret generic jottacloud-backup-secrets \
  --namespace=jottacloud-backup \
  --from-file=RCLONE_CONFIG=$HOME/.config/rclone/rclone.conf \
  --from-literal=S3_ACCESS_KEY="your-new-key" \
  --from-literal=S3_SECRET_KEY="your-new-secret" \
  --from-literal=KOPIA_PASSWORD="your-repo-password" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Monitoring

Optional [healthchecks.io](https://healthchecks.io) integration:

1. Create a check, copy the UUID
2. Set `HEALTHCHECK_UUID` in the secret

## Kopia Repository Management

The container uses a **stable client identity** (`backup@jotta-backup-client`) to avoid creating multiple client entries in your Kopia repository with each container run.

### Client Identity

- **Hostname**: `jotta-backup-client` (consistent across runs)
- **Username**: `backup` (dedicated backup user)
- **Benefits**: Clean policy management, single client identity in repository

### Smart Connection Management

- Only reconnects when S3 parameters change
- Persists repository configuration across CronJob runs
- Automatically detects configuration changes and reconnects

### Logging

- **Main logs**: `/data/logs/backup.log` (kept 30 days)
- **rclone logs**: `/data/logs/rclone/` (kept 7 days)
- **Kopia logs**: `/data/logs/kopia/` (kept 14 days)
- All logs stored on NFS for persistent access

### Policy Management

You can manage backup policies from your local Kopia client:

```bash
# List all clients connected to repository
kopia snapshot list --all

# Set retention policy for the backup client
kopia policy set backup@jotta-backup-client \
  --retention-period=1y \
  --compression=zstd
```

## Manual Operations

```bash
# Run backup immediately
kubectl create job manual-backup-$(date +%s) \
  --from=cronjob/jottacloud-backup-scheduled -n jottacloud-backup

# View logs
kubectl logs -f $(kubectl get jobs -n jottacloud-backup -o name | tail -1) -n jottacloud-backup

# Update to latest image
kubectl delete cronjob jottacloud-backup-scheduled -n jottacloud-backup
kubectl apply -f kubernetes/cronjob.yaml
```

## Security Features

- Non-root user, read-only filesystem
- Dedicated ServiceAccount with minimal permissions
- Network policies restrict egress traffic
- Container signing and SBOM generation
- Automated vulnerability scanning

### Security Philosophy

This project follows a **pragmatic security approach** for service containers:

- **Continuous deployment** - Images are always built and tagged as `latest`, vulnerabilities are tracked but don't block deployment
- **Service continuity over perfection** - Running backups with known low-risk vulnerabilities is better than no backups at all
- **Automated improvement** - Renovate automatically updates dependencies when fixes become available
- **Full visibility** - All vulnerabilities are tracked in GitHub Security tab for review and dismissal decisions
- **Weekly monitoring** - Scheduled scans ensure new vulnerabilities are promptly identified

For upstream vulnerabilities (e.g., Go stdlib issues in Kopia), risks are assessed based on actual usage patterns rather than theoretical exposure.

## Documentation

- [docs/LOCAL_TESTING.md](docs/LOCAL_TESTING.md) - Local testing instructions
- [docs/SIGNING_FLOW.md](docs/SIGNING_FLOW.md) - Container signing and verification explained
