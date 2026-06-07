# Kind Cluster Backup & Restore

Automated backup and restore of kind clusters (CNPG / EDB CNP / PGD4K) via GitHub + Git LFS.

📖 **[View Full Runbook →](https://erswapnil.github.io/Kind-Cluster-Backup-and-restore/)**

## Quick Start

**Backup (source machine)**
```
curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-cluster-backup.sh \
  -o docker-cluster-backup.sh && chmod +x docker-cluster-backup.sh && ./docker-cluster-backup.sh
```

**Restore (destination machine)**
```
curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-cluster-restore.sh \
  -o docker-cluster-restore.sh && chmod +x docker-cluster-restore.sh && ./docker-cluster-restore.sh
```
