#!/bin/sh

# Rclone sync script for Jottacloud
set -e

# Configuration - no defaults for critical paths to prevent masking config failures
# Required from environment: RCLONE_CONFIG_FILE, JOTTA_REMOTE, LOCAL_PATH
# Optional: DEST_REMOTE - name of an rclone remote to sync into instead of
# writing plaintext to LOCAL_PATH directly. Intended for a crypt remote that
# wraps LOCAL_PATH, so data is encrypted at rest. LOCAL_PATH is still required:
# it is the underlying directory used for mkdir and post-sync statistics.
RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"

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

# Resolve sync destination: a named remote (e.g. crypt) or the plain local path
if [ -n "$DEST_REMOTE" ]; then
    if ! rclone --config="$RCLONE_CONFIG_FILE" listremotes | grep -qx "${DEST_REMOTE}:"; then
        log "ERROR: DEST_REMOTE '$DEST_REMOTE' not found in rclone config"
        exit 1
    fi
    # DEST_REMOTE must be a crypt remote wrapping LOCAL_PATH: kopia snapshots
    # LOCAL_PATH (via SOURCE_PATH), so data landing anywhere else would
    # silently escape the backup
    REMOTE_TYPE=$(rclone --config="$RCLONE_CONFIG_FILE" config show "$DEST_REMOTE" | sed -n 's/^type = //p')
    WRAPPED_PATH=$(rclone --config="$RCLONE_CONFIG_FILE" config show "$DEST_REMOTE" | sed -n 's/^remote = //p')
    if [ "$REMOTE_TYPE" != "crypt" ]; then
        log "ERROR: DEST_REMOTE '$DEST_REMOTE' has type '$REMOTE_TYPE', expected 'crypt'"
        exit 1
    fi
    if [ "${WRAPPED_PATH%/}" != "${LOCAL_PATH%/}" ]; then
        log "ERROR: DEST_REMOTE '$DEST_REMOTE' wraps '$WRAPPED_PATH' but LOCAL_PATH is '$LOCAL_PATH' - synced data would escape the kopia backup"
        exit 1
    fi
    SYNC_DEST="${DEST_REMOTE}:"
else
    SYNC_DEST="$LOCAL_PATH"
fi

# Create local directory if it doesn't exist
mkdir -p "$LOCAL_PATH"

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

rclone sync \
    --config="$RCLONE_CONFIG_FILE" \
    --log-level="$RCLONE_LOG_LEVEL" \
    --log-file="$RCLONE_LOG_FILE" \
    --log-file-max-age=7d \
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
    "$JOTTA_REMOTE:" "$SYNC_DEST"

RCLONE_EXIT=$?

if [ $RCLONE_EXIT -eq 0 ]; then
    log "Sync completed successfully"

    # Show final statistics
    log "Final sync statistics:"
    du -sh "$LOCAL_PATH"

    # Count files
    FILE_COUNT=$(find "$LOCAL_PATH" -type f | wc -l)
    log "Total files synced: $FILE_COUNT"

else
    log "ERROR: Sync failed with exit code $RCLONE_EXIT"
    exit $RCLONE_EXIT
fi

log "Rclone sync process completed"