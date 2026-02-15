#!/bin/bash
set -euo pipefail

# Pibox Backup Script
# Backs up k3s data, PostgreSQL databases, and PVC data to Hetzner StorageBox via restic.
#
# Prerequisites:
#   - restic installed on the host
#   - sqlite3 installed on the host
#   - RESTIC_REPOSITORY and RESTIC_PASSWORD_FILE set (or sourced from env file)
#   - SSH key configured for Hetzner StorageBox access
#   - restic repo initialized: restic init

BACKUP_WORK_DIR="/var/lib/rancher/k3s/.pibox-backup-tmp"
K3S_DB="/var/lib/rancher/k3s/server/db/state.db"
K3S_SERVER_DIR="/var/lib/rancher/k3s/server"
LOCAL_PATH_BASE="/var/lib/rancher/k3s/storage"
SMB_STORAGE="/var/lib/rancher/storage"

# Source environment (RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, etc.)
if [ -f /etc/pibox-backup.env ]; then
    set -a
    # shellcheck source=/dev/null
    . /etc/pibox-backup.env
    set +a
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    log "Cleaning up work directory"
    rm -rf "$BACKUP_WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$BACKUP_WORK_DIR"

# --- 1. k3s SQLite snapshot ---
log "Backing up k3s SQLite database"
sqlite3 "$K3S_DB" ".backup '$BACKUP_WORK_DIR/k3s-state.db'"

# Also grab the TLS certs and token (needed to restore a cluster)
cp -a "$K3S_SERVER_DIR/tls" "$BACKUP_WORK_DIR/k3s-tls"
cp "$K3S_SERVER_DIR/token" "$BACKUP_WORK_DIR/k3s-token"

# --- 2. PostgreSQL dump ---
log "Dumping PostgreSQL databases"
POSTGRES_POD=$(kubectl get pods -n postgresql -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
PGPASSWORD=$(kubectl get secret -n postgresql postgresql-secret -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec -n postgresql "$POSTGRES_POD" -- bash -c "PGPASSWORD='$PGPASSWORD' pg_dumpall -U postgres" | gzip > "$BACKUP_WORK_DIR/pg_dumpall.sql.gz"

# --- 3. Sealed Secrets signing key ---
log "Backing up Sealed Secrets keys"
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$BACKUP_WORK_DIR/sealed-secrets-keys.yaml"

# --- 4. Restic backup ---
log "Running restic backup"
restic backup \
    --verbose \
    --tag pibox \
    --exclude='*.sock' \
    --exclude='lost+found' \
    "$BACKUP_WORK_DIR" \
    "$LOCAL_PATH_BASE" \
    "$SMB_STORAGE"

# --- 5. Prune old snapshots ---
log "Pruning old backups"
restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune

log "Backup complete"
