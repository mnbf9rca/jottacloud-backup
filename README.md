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

## Setup

### Prerequisites

- Kubernetes cluster with NFS storage
- Backblaze B2 account
- rclone installed locally (for initial Jottacloud auth)

### 1. Create rclone config

```bash
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
```

> **Note:** Jottacloud tokens rotate aggressively and only one session can be active per config. Each container instance must use its own rclone config — do not share configs between machines. If the config PVC is lost, you will need to generate a new personal login token from the Jottacloud web UI and re-run `rclone config`.

If your local `rclone.conf` contains other remotes, extract just the jotta section:

```bash
rclone config show jotta > /tmp/jotta-rclone.conf
```

### 2. Configure Kubernetes manifests

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

### 3. Create namespace and secrets

```bash
kubectl apply -f kubernetes/pod-security-policy.yaml

kubectl create secret generic jottacloud-backup-secrets \
  --namespace=jottacloud-backup \
  --from-file=RCLONE_CONFIG=$HOME/.config/rclone/rclone.conf \
  --from-literal=S3_ACCESS_KEY='your-b2-key-id' \
  --from-literal=S3_SECRET_KEY='your-b2-app-key' \
  --from-literal=KOPIA_PASSWORD='your-repo-password' \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 4. (Optional) Migrate from proton-drive-backup

If you are replacing an existing [proton-drive-backup](https://github.com/mnbf9rca/proton-drive-backup) deployment that shares the same Kopia repository and NFS storage:

#### 4a. Remove the Proton deployment

Delete all Proton K8s resources — the NFS data is preserved on the NFS server itself:

```bash
kubectl delete cronjob proton-backup-scheduled -n proton-backup
kubectl delete configmap proton-backup-config -n proton-backup
kubectl delete secret proton-backup-secrets -n proton-backup
kubectl delete serviceaccount proton-backup-sa -n proton-backup
kubectl delete networkpolicy proton-backup-network-policy -n proton-backup
kubectl delete pvc proton-backup-data-pvc proton-backup-config-pvc -n proton-backup
kubectl delete pv proton-backup-data-pv proton-backup-config-pv
kubectl delete namespace proton-backup
```

#### 4b. Rename the NFS path

On your NFS server, rename the data directory to match the new PV path:

```bash
mv /tank/largeappdata/proton-drive /tank/largeappdata/jottacloud
```

The first rclone sync will replace the old Proton files with Jottacloud files. Kopia's content-addressable dedup means any identical files between the two are not re-uploaded to B2.

#### 4c. Move Kopia snapshot history

Re-parent existing snapshots to the new client identity. This rewrites snapshot manifests only — no data is re-uploaded. The S3/Kopia credentials are the same (shared B2 bucket and Kopia repo).

```bash
# Dry run first
kopia snapshot move-history \
  backup@proton-backup-client:/data/proton \
  backup@jotta-backup-client:/data/jotta \
  --dry-run

# If that looks correct, run for real
kopia snapshot move-history \
  backup@proton-backup-client:/data/proton \
  backup@jotta-backup-client:/data/jotta
```

#### Rollback

If the first Jottacloud backup fails after moving snapshot history:

```bash
# Reverse the history move
kopia snapshot move-history \
  backup@jotta-backup-client:/data/jotta \
  backup@proton-backup-client:/data/proton

# Rename NFS path back
mv /tank/largeappdata/jottacloud /tank/largeappdata/proton-drive

# Re-deploy proton-drive-backup
```

### 5. Deploy

```bash
kubectl apply -f kubernetes/persistent-volumes.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/serviceaccount.yaml
kubectl apply -f kubernetes/network-policy.yaml
kubectl apply -f kubernetes/cronjob.yaml
```

### 6. Verify

```bash
# Run a manual backup
kubectl create job manual-backup-$(date +%s) \
  --from=cronjob/jottacloud-backup-scheduled -n jottacloud-backup

# Watch the logs
kubectl logs -f $(kubectl get jobs -n jottacloud-backup -o name | tail -1) \
  -n jottacloud-backup
```

## Configuration

### Required Secrets

| Variable         | Description                    |
| ---------------- | ------------------------------ |
| `RCLONE_CONFIG`  | rclone config file (mounted as `/tmp/rclone-secret/rclone.conf`) |
| `S3_ACCESS_KEY`  | Backblaze B2 key ID            |
| `S3_SECRET_KEY`  | Backblaze B2 application key   |
| `KOPIA_PASSWORD` | Repository encryption password |

Non-sensitive config like `HEALTHCHECK_UUID`, `S3_ENDPOINT`, and `S3_BUCKET` goes in the ConfigMap (`kubernetes/configmap.yaml`).

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
kubectl logs -f $(kubectl get jobs -n jottacloud-backup -o name | tail -1) \
  -n jottacloud-backup
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
