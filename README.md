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
| `DEST_REMOTE` | Name of an rclone crypt remote (without the trailing `:`) to sync into instead of writing plaintext to `LOCAL_PATH`. See [Encryption at rest](#encryption-at-rest-optional). |
| `RCLONE_CONFIG_<NAME>_*` | Standard rclone env-var remote definition — the recommended way to supply the crypt remote without touching the config file. |

## Encryption at rest (optional)

Set `DEST_REMOTE` and the sync writes through an rclone [crypt remote](https://rclone.org/crypt/) instead of straight to `LOCAL_PATH`: same directory on disk, but file contents are encrypted. Kopia backs up the ciphertext unchanged. Unset = plaintext, exactly as before.

### Configuration

Five variables. Everything except the password is non-secret and goes in the **ConfigMap**; the password goes in the **Secret** (both already reach the container via `envFrom`). Do **not** add the remote to `rclone.conf` — the live Jottacloud OAuth token lives in that file and rewriting it clobbers the token.

| Variable | Where | Value |
| --- | --- | --- |
| `RCLONE_CONFIG_JOTTACRYPT_TYPE` | ConfigMap | `crypt` |
| `RCLONE_CONFIG_JOTTACRYPT_REMOTE` | ConfigMap | same path as `LOCAL_PATH` (e.g. `/data/jotta`) |
| `RCLONE_CONFIG_JOTTACRYPT_FILENAME_ENCRYPTION` | ConfigMap | `off` or `standard`, see below |
| `DEST_REMOTE` | ConfigMap | `jottacrypt` (the remote name — lowercase/digits only) |
| `RCLONE_CONFIG_JOTTACRYPT_PASSWORD` | Secret | output of `rclone obscure '<passphrase>'` |

Filename encryption: `off` keeps real names (+`.bin`, components ≤251 bytes; contents still encrypted); `standard` encrypts names too but caps path components at 143 **bytes** — one longer name breaks every run. Check before choosing `standard`:
`find /path/to/data | LC_ALL=C awk -F/ '{for(i=1;i<=NF;i++) if (length($i)>143) {print; next}}'`

⚠️ The passphrase can never be lost **or rotated** — crypt cannot rekey, and either event makes the local copy and every Kopia snapshot unrecoverable. Keep it in a password manager. (`rclone obscure` output is reversible encoding, not protection.)

### Guardrails (enforced by the script, no action needed)

- Refuses to sync unless `DEST_REMOTE` is a real crypt remote whose writes land inside `LOCAL_PATH` (and `SOURCE_PATH`, if set, equals `LOCAL_PATH`) — anything else would escape the Kopia backup or silently skip encryption.
- A key canary (`.crypt-key-canary`) written on the first crypt run must decrypt to a known value before every sync — catches a changed password or filename mode while it is still harmless. (With `filename_encryption=off` nothing else can catch it: listing and counts work under any key.)
- A sentinel (`.encrypted-by-dest-remote`) latches the directory: plaintext-mode runs refuse while it exists, because a plaintext sync into a ciphertext directory deletes everything and re-downloads in plaintext with exit 0. Delete it only to deliberately decommission encryption.
- After each sync, files on disk must equal files decryptable through the remote — catches residual plaintext and foreign files. (A killed run can leave `*.partial` files that trip this; remove them and re-run.)

### Migrating an existing plaintext copy

Encrypt in place wherever the volume is accessible (no re-download; ciphertext is path-independent). Run each block separately and check the cryptcheck exit code before deleting anything:

```bash
mv /data/jotta /data/jotta-plain && mkdir -p /data/jotta

export RCLONE_CONFIG_JOTTACRYPT_TYPE=crypt \
       RCLONE_CONFIG_JOTTACRYPT_REMOTE=/data/jotta \
       RCLONE_CONFIG_JOTTACRYPT_FILENAME_ENCRYPTION=off \
       RCLONE_CONFIG_JOTTACRYPT_PASSWORD='<obscured>'

rclone sync /data/jotta-plain jottacrypt: --progress
rclone cryptcheck /data/jotta-plain jottacrypt: ; echo "cryptcheck exit: $?"
```

If (and only if) cryptcheck exited 0, pre-seed the guardrail markers, then delete the plaintext as a separate deliberate step:

```bash
printf 'jottacloud-backup-key-canary-v1' | rclone rcat jottacrypt:.crypt-key-canary
touch /data/jotta/.encrypted-by-dest-remote
```

```bash
rm -rf /data/jotta-plain
```

The first Kopia snapshot afterwards is a full re-upload (all-new ciphertext). Keep pre-migration snapshots until the encrypted ones have real age.

### Restoring

Same env vars, `REMOTE` pointed at wherever the ciphertext sits:

```bash
rclone copy jottacrypt: /path/to/restore
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
