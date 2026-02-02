#!/bin/bash

# Configuration
SSH_DIR="$HOME/.ssh"
EXCLUDE_FILE="authorized_keys"

usage() {
    echo "Usage: $0 [user@hostname]"
    echo "Example: $0 antoine@192.168.122.23"
    exit 1
}

if [ -z "$1" ]; then
    usage
fi

REMOTE="$1"

echo "Starting SSH configuration replication to ${REMOTE}..."

echo "[1/3] Checking connectivity and preparing remote directory..."
ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE" "mkdir -p .ssh && chmod 700 .ssh"
if [ $? -ne 0 ]; then
    # Try interactive if batch mode fails (maybe first connect/password needed)
    echo "Batch mode failed or password required. Retrying interactively..."
    ssh "$REMOTE" "mkdir -p .ssh && chmod 700 .ssh"
    if [ $? -ne 0 ]; then
        echo "Error: Cannot connect to $REMOTE or create .ssh directory."
        exit 1
    fi
fi

# We exclude authorized_keys to avoid locking out the current user if their key isn't in the source authorized_keys.
# We also exclude known_hosts potentially? No, known_hosts is useful.
# We DEFINITELY want config, id_*, etc.
echo "[2/3] Syncing files..."

if command -v rsync &> /dev/null; then
    rsync -avz --exclude "$EXCLUDE_FILE" "$SSH_DIR/" "$REMOTE:.ssh/"
else
    echo "rsync not found, falling back to scp..."
    # Create a temporary tarball to preserve permissions and handle multiple files
    TAR_FILE="/tmp/ssh_replication_$(date +%s).tar.gz"
    tar -czf "$TAR_FILE" -C "$HOME" .ssh --exclude "$EXCLUDE_FILE"
    scp "$TAR_FILE" "$REMOTE:/tmp/"
    ssh "$REMOTE" "tar -xzf /tmp/$(basename "$TAR_FILE") -C ~/ && rm /tmp/$(basename "$TAR_FILE")"
    rm "$TAR_FILE"
fi

if [ $? -eq 0 ]; then
    echo "[3/3] Fix permissions on remote..."
    ssh "$REMOTE" "chmod 700 .ssh && chmod 600 .ssh/id_*"
    
    echo "SUCCESS! SSH configuration replicated to ${REMOTE}."
else
    echo "Error during file transfer."
    exit 1
fi
