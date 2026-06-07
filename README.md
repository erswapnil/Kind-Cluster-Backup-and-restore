# Kind Cluster Backup & Restore

Automated backup and restore of kind clusters (CNPG / EDB CNP / PGD4K) via GitHub + Git LFS.

📖 **[View Full Runbook →](https://erswapnil.github.io/Kind-Cluster-Backup-and-restore/)**

---

## Prerequisites

Run the matching prereq script **once** on each machine before backup or restore.

**Source machine (before backup)**
```
curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-backup-prerequisite.sh \
  -o docker-backup-prerequisite.sh && chmod +x docker-backup-prerequisite.sh && ./docker-backup-prerequisite.sh
```

**Target machine (before restore)**
```
curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-restore-prerequisite.sh \
  -o docker-restore-prerequisite.sh && chmod +x docker-restore-prerequisite.sh && ./docker-restore-prerequisite.sh
```

Both scripts check and auto-install: `Homebrew` · `Docker Desktop` · `kind` · `kubectl` · `git` · `git-lfs` · `python3` · `curl`

> ⚠️ Docker Desktop must be running (whale icon solid in menu bar) before running backup or restore.  
> ⚠️ A GitHub PAT with `repo` scope is required for **backup** (not needed for restore).

---

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

---

## Supported Operators

| Namespace | Operator |
|---|---|
| `cnpg-system` | Community CloudNativePG |
| `postgresql-operator-system` | EDB Postgres for Kubernetes (EDB CNP) |
| `pgd-operator-system` | EDB Postgres Distributed / PGD4K |

---

## How It Works

- **Backup** — auto-detects operator type & version, snapshots the kind control-plane via `docker commit`, exports all K8s resources and CRDs, and pushes everything to a GitHub folder using Git LFS for the snapshot tar.
- **Restore** — lists available backups from GitHub, downloads the selected folder, loads the Docker image, recreates the kind cluster, installs the exact operator version, and applies all configs automatically.

📖 For full details, prompts, and troubleshooting → **[View the Runbook](https://erswapnil.github.io/Kind-Cluster-Backup-and-restore/)**
