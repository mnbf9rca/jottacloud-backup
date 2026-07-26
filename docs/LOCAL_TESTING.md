# Local Testing - Quick Start

## Setup rclone

1. Install rclone (v1.71.0+)
2. Configure rclone:
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
```

## Test Connection
```bash
rclone lsd jotta:
```

## Run Script

Set environment variables:
```bash
export RCLONE_CONFIG_FILE="$HOME/.config/rclone/rclone.conf"
export JOTTA_REMOTE="jotta"
export LOCAL_PATH="/tmp/jotta-backup-test"
# Optional: encrypt at rest - the script derives the crypt remote itself
# export DEST_REMOTE="jottacrypt"
# export DEST_REMOTE_PASSWORD="test-passphrase"
```

Run:
```bash
./scripts/rclone-sync.sh
```

## Docker Test

```bash
# Build
docker build -t jottacloud-backup-test .

# Run
docker run --rm -it \
  -v ~/.config/rclone/rclone.conf:/config/rclone.conf:ro \
  -v /tmp/jotta-data:/data \
  -e RCLONE_CONFIG_FILE="/config/rclone.conf" \
  -e JOTTA_REMOTE="jotta" \
  -e LOCAL_PATH="/data/jotta" \
  jottacloud-backup-test \
  /scripts/rclone-sync.sh
```

## Common Issues

- **"jottacloud not found"**: Update rclone to v1.71.0 or later
- **"Token expired"**: Jottacloud tokens rotate aggressively; generate a new personal login token from the web UI and re-run `rclone config reconnect jotta:`
- **"Config file not found"**: Check RCLONE_CONFIG_FILE path
