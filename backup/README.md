# Pibox Backup

Daily backups to Hetzner StorageBox via [restic](https://restic.net/) over SFTP.

## What's backed up

| Data | Source | Method |
|------|--------|--------|
| k3s datastore | `/var/lib/rancher/k3s/server/db/state.db` | SQLite `.backup` command |
| k3s TLS certs & token | `/var/lib/rancher/k3s/server/{tls,token}` | File copy |
| PostgreSQL databases | All databases | `pg_dumpall` via kubectl exec |
| Sealed Secrets signing key | kube-system secret | kubectl get |
| PVC data (git repos, weather CSVs, etc.) | `/var/lib/rancher/k3s/storage/` | Restic incremental backup |

## Setup

Run the Ansible playbook (it will prompt for your StorageBox username):

```bash
cd backup/
ansible-playbook -i inventory.ini playbook.yml --ask-pass
```

The playbook will:
1. Install restic and sqlite3
2. Generate an SSH key and prompt you to install it on the StorageBox
3. Generate and save a restic repository password (save it somewhere safe!)
4. Create the environment and config files
5. Initialize the restic repository
6. Install and enable the systemd timer
7. Optionally run the first backup

### Checking status

```bash
# Timer status
sudo systemctl status pibox-backup.timer

# Last run output
sudo journalctl -u pibox-backup.service -e

# List snapshots
sudo restic snapshots
```

## Restore

### PostgreSQL

```bash
# Copy dump from a snapshot
restic restore latest --target /tmp/restore --include pg_dumpall.sql.gz

# Restore into the running cluster
gunzip -c /tmp/restore/tmp/pibox-backup/pg_dumpall.sql.gz | \
  kubectl exec -i -n postgresql $POSTGRES_POD -- psql -U postgres
```

### k3s state

```bash
# Stop k3s
sudo systemctl stop k3s

# Restore the database
restic restore latest --target /tmp/restore --include k3s-state.db
sudo cp /tmp/restore/tmp/pibox-backup/k3s-state.db /var/lib/rancher/k3s/server/db/state.db

# Restore TLS certs if needed
restic restore latest --target /tmp/restore --include k3s-tls
sudo cp -a /tmp/restore/tmp/pibox-backup/k3s-tls/* /var/lib/rancher/k3s/server/tls/

# Start k3s
sudo systemctl start k3s
```

### PVC data

```bash
# List files in a snapshot
restic ls latest --path /var/lib/rancher/k3s/storage/

# Restore specific PVC data
restic restore latest --target / --include /var/lib/rancher/k3s/storage/pvc-XXXXX
```

### Sealed Secrets key

```bash
restic restore latest --target /tmp/restore --include sealed-secrets-keys.yaml
kubectl apply -f /tmp/restore/tmp/pibox-backup/sealed-secrets-keys.yaml
# Restart the sealed-secrets controller to pick up the key
kubectl rollout restart deployment -n kube-system sealed-secrets-controller
```

## Retention policy

| Period | Kept |
|--------|------|
| Daily | 7 |
| Weekly | 4 |
| Monthly | 6 |

Adjust in `pibox-backup.sh` in the `restic forget` call.
