#!/bin/sh

# Rclone sync script for Jottacloud
set -e

# Configuration - no defaults for critical paths to prevent masking config failures
# Required from environment: RCLONE_CONFIG_FILE, JOTTA_REMOTE, LOCAL_PATH
# Optional: DEST_REMOTE - name of an rclone remote to sync into instead of
# writing plaintext to LOCAL_PATH directly. Intended for a crypt remote that
# wraps LOCAL_PATH, so data is encrypted at rest. The remote may be defined in
# the config file or entirely via RCLONE_CONFIG_<NAME>_* env vars. LOCAL_PATH
# is still required: it is the physical directory (kopia snapshots it, and the
# post-sync verification counts files in it).
RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"

# Marker written to LOCAL_PATH on the first crypt-mode run. A later
# plaintext-mode run (DEST_REMOTE unset) refuses when it is present: rclone
# sync would otherwise treat all ciphertext as extraneous, DELETE it, and
# re-download everything in plaintext while exiting 0.
SENTINEL_NAME=".encrypted-by-dest-remote"

# Persistent key canary: written through the crypt remote on the first crypt
# run and required to decrypt to this exact value on every later run. This is
# the ONLY detection for a changed password or filename_encryption mode in
# filename_encryption=off deployments: names are not encrypted there, so
# listing and file counts succeed under ANY key, and sync no-ops on
# size/modtime without ever authenticating contents. The value must never
# change across versions - existing deployments have it baked into ciphertext.
KEY_CANARY_NAME=".crypt-key-canary"
KEY_CANARY_VALUE="jottacloud-backup-key-canary-v1"

# Function to log with timestamp
log() {
    echo "[$(date)] [RCLONE] $1"
}

# Validate required configuration
if [ -z "$RCLONE_CONFIG_FILE" ]; then
    log "ERROR: RCLONE_CONFIG_FILE environment variable is required"
    exit 1
fi

if [ -z "$JOTTA_REMOTE" ]; then
    log "ERROR: JOTTA_REMOTE environment variable is required"
    exit 1
fi

if [ -z "$LOCAL_PATH" ]; then
    log "ERROR: LOCAL_PATH environment variable is required"
    exit 1
fi

if [ ! -f "$RCLONE_CONFIG_FILE" ]; then
    log "ERROR: Rclone config file not found at $RCLONE_CONFIG_FILE"
    exit 1
fi

# Create local directory if it doesn't exist (needed before canary validation)
mkdir -p "$LOCAL_PATH"

# Resolve sync destination: a named remote (crypt) or the plain local path.
# Validation is behavioural, not config-parsing, so it works identically for
# file-defined and env-var-defined remotes.
if [ -n "$DEST_REMOTE" ]; then
    if ! rclone --config="$RCLONE_CONFIG_FILE" listremotes | grep -qxF "${DEST_REMOTE}:"; then
        log "ERROR: DEST_REMOTE '$DEST_REMOTE' not found (config file or RCLONE_CONFIG_* env vars)"
        exit 1
    fi
    # Type check: the 'encode' backend command exists only on crypt remotes.
    # A non-crypt remote here would silently sync PLAINTEXT while the operator
    # believes encryption is on.
    CANARY_NAME=".dest-remote-canary"
    if ! ENC_CANARY=$(rclone --config="$RCLONE_CONFIG_FILE" backend encode "$DEST_REMOTE:" "$CANARY_NAME" 2>/dev/null); then
        log "ERROR: DEST_REMOTE '$DEST_REMOTE' is not a crypt remote - refusing to sync unencrypted"
        exit 1
    fi
    # Path check: a write through the remote must physically land inside
    # LOCAL_PATH - kopia snapshots LOCAL_PATH, so data anywhere else silently
    # escapes the backup.
    if ! printf 'canary' | rclone --config="$RCLONE_CONFIG_FILE" rcat "$DEST_REMOTE:$CANARY_NAME"; then
        log "ERROR: test write to '$DEST_REMOTE:' failed"
        exit 1
    fi
    if [ ! -f "$LOCAL_PATH/$ENC_CANARY" ]; then
        rclone --config="$RCLONE_CONFIG_FILE" deletefile "$DEST_REMOTE:$CANARY_NAME" 2>/dev/null || true
        log "ERROR: DEST_REMOTE '$DEST_REMOTE' does not wrap LOCAL_PATH '$LOCAL_PATH' - synced data would escape the kopia backup"
        exit 1
    fi
    rclone --config="$RCLONE_CONFIG_FILE" deletefile "$DEST_REMOTE:$CANARY_NAME" 2>/dev/null || true
    # kopia snapshots SOURCE_PATH; the canary only proves writes land in
    # LOCAL_PATH. If the two differ, encrypted data never reaches the backup.
    if [ -n "$SOURCE_PATH" ] && [ "${SOURCE_PATH%/}" != "${LOCAL_PATH%/}" ]; then
        log "ERROR: SOURCE_PATH ('$SOURCE_PATH') != LOCAL_PATH ('$LOCAL_PATH') - kopia would snapshot a different directory than the one receiving ciphertext"
        exit 1
    fi
    # Key-continuity check (see KEY_CANARY_NAME comment above). The transient
    # canary was written and checked under the CURRENT password, so it proves
    # nothing about key continuity across runs.
    if [ -e "$LOCAL_PATH/$SENTINEL_NAME" ]; then
        KEY_CHECK=$(rclone --config="$RCLONE_CONFIG_FILE" cat "$DEST_REMOTE:$KEY_CANARY_NAME" 2>/dev/null || true)
        if [ "$KEY_CHECK" != "$KEY_CANARY_VALUE" ]; then
            log "ERROR: key canary '$KEY_CANARY_NAME' did not decrypt to the expected value"
            log "ERROR: the crypt password or filename_encryption mode changed since this directory was encrypted"
            log "ERROR: syncing now would mix ciphertext under two keys; restore the original password/mode"
            exit 1
        fi
    else
        # First crypt run: write the canary, then latch the directory
        if ! printf '%s' "$KEY_CANARY_VALUE" | rclone --config="$RCLONE_CONFIG_FILE" rcat "$DEST_REMOTE:$KEY_CANARY_NAME"; then
            log "ERROR: failed to write key canary to '$DEST_REMOTE:'"
            exit 1
        fi
        touch "$LOCAL_PATH/$SENTINEL_NAME"
    fi
    SYNC_DEST="${DEST_REMOTE}:"
else
    if [ -e "$LOCAL_PATH/$SENTINEL_NAME" ]; then
        log "ERROR: $LOCAL_PATH is marked encrypted ($SENTINEL_NAME present) but DEST_REMOTE is not set"
        log "ERROR: a plaintext sync would DELETE the ciphertext and re-download everything in plaintext"
        log "ERROR: set DEST_REMOTE, or delete the sentinel file to deliberately decommission encryption"
        exit 1
    fi
    SYNC_DEST="$LOCAL_PATH"
fi

log "Starting Jottacloud sync..."
log "Remote: $JOTTA_REMOTE"
log "Local path: $LOCAL_PATH"
log "Sync destination: $SYNC_DEST"
log "Config file: $RCLONE_CONFIG_FILE"

# Test connection first
log "Testing connection to Jottacloud..."
if ! rclone --config="$RCLONE_CONFIG_FILE" lsd "$JOTTA_REMOTE:" --max-depth 1; then
    log "ERROR: Failed to connect to Jottacloud remote '$JOTTA_REMOTE'"
    exit 1
fi

log "Connection test successful, starting sync..."

# Ensure destination directory exists and is writable
log "Checking current user and permissions..."
id
log "Checking data mount permissions..."
ls -la "/data" || true

log "Creating destination directory: $LOCAL_PATH"
mkdir -p "$LOCAL_PATH" || {
    log "ERROR: Failed to create directory $LOCAL_PATH"
    log "Data directory permissions:"
    ls -la "/data" || true
    log "Parent directory permissions:"
    ls -la "$(dirname "$LOCAL_PATH")" || true
    exit 1
}

# Perform the sync with comprehensive logging
# Using sync instead of copy to handle deletions
log "Starting rclone sync from $JOTTA_REMOTE: to $SYNC_DEST"

# Create rclone logs directory
RCLONE_LOG_DIR="/data/logs/rclone"
mkdir -p "$RCLONE_LOG_DIR"
RCLONE_LOG_FILE="$RCLONE_LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"

# Prune old sync logs ourselves. rclone's --log-file-max-age only manages
# rotated copies of the single file it is writing; with a unique filename per
# run nothing is ever rotated, so old logs accumulate forever without this.
find "$RCLONE_LOG_DIR" -name 'sync-*.log' -mtime +7 -delete 2>/dev/null || true

# Captured via || below so the failure branch stays reachable under set -e
RCLONE_EXIT=0
rclone sync \
    --config="$RCLONE_CONFIG_FILE" \
    --log-level="$RCLONE_LOG_LEVEL" \
    --log-file="$RCLONE_LOG_FILE" \
    --stats=1m \
    --stats-one-line \
    --progress \
    --check-first \
    --create-empty-src-dirs \
    --exclude-if-present .rcloneignore \
    --retries=3 \
    --retries-sleep=30s \
    --timeout=10m \
    --contimeout=60s \
    --low-level-retries=10 \
    --exclude="/$KEY_CANARY_NAME" \
    "$JOTTA_REMOTE:" "$SYNC_DEST" || RCLONE_EXIT=$?

if [ $RCLONE_EXIT -eq 0 ]; then
    log "Sync completed successfully"

    # Show final statistics
    log "Final sync statistics:"
    du -sh "$LOCAL_PATH"

    # Count files
    FILE_COUNT=$(find "$LOCAL_PATH" -type f | wc -l)
    log "Total files synced: $FILE_COUNT"

    # Crypt mode: verify everything on disk is decryptable through the
    # remote. Leftover plaintext, key-mismatched ciphertext or foreign files
    # are invisible to crypt (it skips what it cannot decode, exit 0) while
    # du/find above count them as if synced - so a mismatch here is the only
    # signal that unencrypted or unrestorable data is sitting in LOCAL_PATH.
    if [ -n "$DEST_REMOTE" ]; then
        DISK_COUNT=$(find "$LOCAL_PATH" -type f ! -name "$SENTINEL_NAME" | wc -l)
        CRYPT_COUNT=$(rclone --config="$RCLONE_CONFIG_FILE" lsf -R --files-only "$DEST_REMOTE:" | wc -l)
        if [ "$DISK_COUNT" -ne "$CRYPT_COUNT" ]; then
            log "ERROR: $DISK_COUNT files on disk under $LOCAL_PATH but $CRYPT_COUNT decryptable via '$DEST_REMOTE:'"
            log "ERROR: difference = residual plaintext or foreign files (key drift is caught by the key canary before sync)"
            log "HINT: a run killed mid-transfer can leave *.partial files behind - inspect and remove them, then re-run"
            exit 1
        fi
        log "Ciphertext verification passed: $CRYPT_COUNT files, all decryptable"
    fi

else
    log "ERROR: Sync failed with exit code $RCLONE_EXIT"
    exit $RCLONE_EXIT
fi

log "Rclone sync process completed"