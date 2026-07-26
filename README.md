# Jottacloud Backup Container

Automated, secure backup of Jottacloud to Backblaze B2 using rclone and Kopia in Kubernetes.

## Features

- **Security First**: Non-root user, minimal Alpine base, signed container images
- **Multi-Architecture**: Supports amd64 and arm64
- **Monitoring**: Built-in healthchecks.io integration
- **Kubernetes Native**: CronJob-based scheduled backups

## How It Works

1. **rclone** downloads Jottacloud files to local storage (optionally encrypted at rest via a crypt remote — see [Encryption at rest](#encryption-at-rest-optional))
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
# Then use /tmp/jotta-rclone.conf instead of $HOME/.config/rclone/rclone.conf
# in the secret creation step below
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

Create a Longhorn volume named `jottacloud-backup-config` (10Gi) via the Longhorn UI. This is used by the config PV to persist rclone and Kopia state across runs.

### 3. Create namespace and secrets

```bash
kubectl apply -f kubernetes/pod-security-policy.yaml

kubectl create secret generic jottacloud-backup-secrets \
  --namespace=jottacloud-backup \
  --from-file=RCLONE_CONFIG="$HOME/.config/rclone/rclone.conf" \
  --from-literal=S3_ACCESS_KEY='your-b2-key-id' \
  --from-literal=S3_SECRET_KEY='your-b2-app-key' \
  --from-literal=KOPIA_PASSWORD='your-repo-password' \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 4. (Optional) Migrate from proton-drive-backup

If you are replacing an existing [proton-drive-backup](https://github.com/mnbf9rca/proton-drive-backup) deployment that shares the same Kopia repository and NFS storage:

#### 4a. Copy secrets from proton

Since both containers share the same B2 bucket and Kopia repo, copy the existing secret and replace the rclone config:

```bash
# Copy the proton secret to the new namespace (created by step 3)
kubectl get secret proton-backup-secrets -n proton-backup -o json | \
  jq '.metadata = {name: "jottacloud-backup-secrets", namespace: "jottacloud-backup"}' | \
  kubectl apply -f -

# Patch just the rclone config key (keeps S3/Kopia credentials intact)
RCLONE_B64=$(base64 < /tmp/jotta-rclone.conf | tr -d '\n')
kubectl patch secret jottacloud-backup-secrets -n jottacloud-backup \
  -p "{\"data\":{\"RCLONE_CONFIG\":\"$RCLONE_B64\"}}"
```

You can skip step 3's `kubectl create secret` command if you do this.

#### 4b. Stop the Proton deployment

Remove the CronJob and supporting resources, but keep secrets and configmap for rollback:

```bash
kubectl delete cronjob proton-backup-scheduled -n proton-backup
kubectl delete serviceaccount proton-backup-sa -n proton-backup
kubectl delete networkpolicy proton-backup-network-policy -n proton-backup
kubectl delete pvc proton-backup-data-pvc proton-backup-config-pvc -n proton-backup
kubectl delete pv proton-backup-data-pv proton-backup-config-pv
```

#### 4c. Rename paths on the NFS server

Rename both the top-level NFS export and the data subdirectory so they match the new PV and `LOCAL_PATH` config:

```bash
# Rename the NFS export to match the new PV path
mv /tank/largeappdata/proton-drive /tank/largeappdata/jottacloud

# Rename the data subdirectory to match LOCAL_PATH (/data/jotta)
mv /tank/largeappdata/jottacloud/proton /tank/largeappdata/jottacloud/jotta
```

The first rclone sync will compare the existing files against Jottacloud and only download the differences. Kopia's content-addressable dedup means identical files are not re-uploaded to B2.

#### 4d. Move Kopia snapshot history

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

# Transfer maintenance ownership to the new identity
kopia maintenance set --owner backup@jotta-backup-client
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

### 7. (Migration only) Clean up proton namespace

Once the Jottacloud backup is running successfully, remove the remaining proton resources:

```bash
kubectl delete namespace proton-backup
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

### Optional Environment Variables

| Variable      | Description                                                                                     |
| ------------- | ----------------------------------------------------------------------------------------------- |
| `DEST_REMOTE` | Name of an rclone remote (without the trailing `:`) to sync into instead of writing plaintext to `LOCAL_PATH`. Intended for a crypt remote wrapping `LOCAL_PATH`. |

## Encryption at rest (optional)

By default, the synced Jottacloud files sit in plaintext on the storage backing `LOCAL_PATH`. If that storage is a physical disk you care about (theft, disposal, RMA), you can have rclone encrypt everything it writes — file contents **and** file names — by layering a [crypt remote](https://rclone.org/crypt/) over `LOCAL_PATH`.

### 1. Add a crypt remote to your rclone config

Append to the same `rclone.conf` that holds the `jotta` remote:

```ini
[jotta-crypt]
type = crypt
remote = /data/jotta
password = <output of: rclone obscure 'your-passphrase'>
```

Notes:

- `remote` is the path **inside the container**, i.e. `LOCAL_PATH`.
- `password` must be the *obscured* form (`rclone obscure ...`), not the raw passphrase.
- `password2` (salt) is optional; omitting it keeps the pipeline down to a single passphrase to safeguard.
- **If you lose the passphrase, the synced copy — and any Kopia snapshots of it — are unrecoverable.** Store it in a password manager.

### 2. Set `DEST_REMOTE` in the ConfigMap

```yaml
DEST_REMOTE: "jotta-crypt"
```

The sync then runs `rclone sync jotta: jotta-crypt:` and ciphertext lands under `LOCAL_PATH`. Kopia is unaffected — it snapshots `SOURCE_PATH` as usual and simply backs up ciphertext. Deduplication still works because rclone only rewrites files that changed.

### Migrating an existing plaintext copy

To avoid re-downloading everything from Jottacloud, encrypt the existing local copy in place before enabling the schedule (run inside a container/pod with the data volume and rclone config mounted):

```bash
# Move the plaintext aside (instant on the same filesystem)
mv /data/jotta /data/jotta-plain
mkdir -p /data/jotta

# Encrypt locally - no internet bandwidth used
rclone sync --config=/config/rclone.conf /data/jotta-plain jotta-crypt: --progress

# Verify, then remove the plaintext
rclone cryptcheck --config=/config/rclone.conf /data/jotta-plain jotta-crypt:
rm -rf /data/jotta-plain
```

The next Kopia snapshot after migration re-uploads everything (every file has new encrypted names/content), so expect a one-time full upload to B2. Consider pruning pre-migration snapshots once the new ones are verified.

### Restoring encrypted data

Ciphertext restored from Kopia (or read straight off the disk) is decrypted with the same crypt remote definition:

```bash
rclone copy jotta-crypt: /path/to/restore --config=/path/to/rclone.conf
```

## Monitoring

Optional [healthchecks.io](https://healthchecks.io) integration:

1. Create a check, copy the UUID
2. Set `HEALTHCHECK_UUID` in the ConfigMap (`kubernetes/configmap.yaml`)

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
