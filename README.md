## Overview

This runbook covers two shell scripts that automate full backup and restore of a **kind (Kubernetes IN Docker) cluster,** including the CNPG/CNP/PGD operator and all PostgreSQL databases, by pushing artifacts directly to a **GitHub repository** using Git LFS for large files.

The automation supports all three EDB operator types:

- cnpg-system: Community CloudNativePG
- postgresql-operator-system: EDB Postgres for Kubernetes (EDB CNP)
- pgd-operator-system: EDB Postgres Distributed / PGD4K (Global Cluster)

------

## The Two Scripts

| **Script**                | **Purpose**                                                  | **Run On**          |
| ------------------------- | ------------------------------------------------------------ | ------------------- |
| docker-cluster-backup.sh  | Snapshots a running kind cluster and uploads all artifacts to GitHub | Source machine      |
| docker-cluster-restore.sh | Fetches a backup from GitHub and rebuilds the cluster        | Destination machine |

------

## Step 0: Prerequisites (Run Once Per Machine)

Run the matching prerequisite script **once** on each machine before the first backup or restore. Takes about 1–2 minutes.

### Source machine (before backup)

curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-backup-prerequisite.sh -o docker-backup-prerequisite.sh && chmod +x docker-backup-prerequisite.sh && ./docker-backup-prerequisite.sh

**What it checks and installs:** Homebrew, Docker Desktop, kind, kubectl, git, git-lfs, python3, curl.

### Target machine (before restore)

curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-restore-prerequisite.sh -o docker-restore-prerequisite.sh && chmod +x docker-restore-prerequisite.sh && ./docker-restore-prerequisite.sh

**What it checks and installs:** Homebrew, Docker Desktop, kind, kubectl, git, git-lfs, python3, curl. Also checks disk space and Docker resource allocation.

ℹ️ **Docker Desktop** is installed automatically via brew install --cask docker if not present. After installation, complete the setup wizard once (accept the license) and wait for the whale icon in the menu bar to go solid, then re-run the prereq script.

⚠️ **git-lfs must be installed before backup or restore.** The prereq scripts handle this automatically. If you skip the prereq, install it manually: brew install git-lfs && git lfs install

------

## Quick Start

### 1. Backup a cluster (source machine)

curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-cluster-backup.sh -o docker-cluster-backup.sh && chmod +x docker-cluster-backup.sh && ./docker-cluster-backup.sh

### 2. Restore a cluster (destination machine)

curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-cluster-restore.sh -o docker-cluster-restore.sh && chmod +x docker-cluster-restore.sh && ./docker-cluster-restore.sh

------

## Script 1: docker-cluster-backup.sh

Run on the **source machine** where the kind cluster is currently running.

⚠️ **Before running:** Docker Desktop must be running (whale icon solid) and at least one kind cluster must be running. You will need a GitHub Personal Access Token with repo scope to push the backup.

### What it asks you

| **Prompt**           | **Details**                                                  |
| -------------------- | ------------------------------------------------------------ |
| 1 · Pick cluster     | Shows a numbered list of all running kind control-plane containers: enter a number |
| 2 · Operator type    | ✅ Auto-detected from namespaces: no input needed             |
| 3 · Operator version | ✅ Auto-detected from container images: no input needed       |
| 4 · GitHub username  | Your GitHub username (default: erswapnil)                    |
| 5 · GitHub PAT       | 🔒 Hidden input: paste token, nothing echoed to terminal. Set GITHUB_TOKEN env var to skip. |
| 6 · GitHub repo      | Default: Kind-Cluster-Backup-and-restore: press Enter to accept |
| 7 · Confirm          | Shows cluster name, operator type, GitHub target: type **Y** to proceed |

🔑 **GitHub PAT is required for backup (but NOT for restore).** Even on a public repo, pushing requires authentication. Create a token with repo scope at [github.com/settings/tokens](https://github.com/settings/tokens).

To avoid re-entering the token, add to your shell profile (~/.zshrc):

export GITHUB_TOKEN=ghp_your_token_here

### What it does automatically

- **Auto-detect operator**: scans all three operator namespaces and reads the version from container images
- **docker commit + save**: snapshots the control-plane container into cnpg-snapshot.tar (~500 MB)
- **kubectl export**: exports all K8s resources to cnp-cluster-config.yaml
- **CRD export**: exports all Cluster/Pooler/PGD CRDs + cert-manager to cnpg-db-blueprints.yaml (**critical**: without this, no databases appear on restore)
- **Metadata files** : writes cnpg-version.txt, operator-namespace.txt, cert-manager-version.txt
- **GitHub upload**: clones the repo, copies all files to <cluster-name>/ folder, commits and pushes (tar via Git LFS)

### GitHub folder structure after backup

Kind-Cluster-Backup-and-restore/

└── <cluster-name>/

  ├── cnpg-snapshot.tar      ← ~500 MB Docker image snapshot (Git LFS)

  ├── cnp-cluster-config.yaml   ← K8s resources (pods, secrets, configmaps)

  ├── cnpg-db-blueprints.yaml   ← PostgreSQL CRDs ⚠️ critical

  ├── cnpg-version.txt       ← e.g. "1.29.1" (auto-detected)

  ├── operator-namespace.txt    ← e.g. "cnpg-system" (auto-detected)

  └── cert-manager-version.txt   ← present only if cert-manager is installed

------

## Script 2: docker-cluster-restore.sh

Run on the **destination machine**:  a colleague's laptop or any remote machine.

✅ **No GitHub PAT needed for restore**: reads from the public repo using the GitHub API and git clone without authentication. Anyone can restore from a public backup.

⚠️ **Before running:** Docker Desktop must be running (whale icon solid, not animated). Ensure git-lfs is installed; the snapshot tar is stored via Git LFS and requires it to download.

### What it asks you

| **Prompt**             | **Details**                                                  |
| ---------------------- | ------------------------------------------------------------ |
| 1 · GitHub username    | Default: erswapnil- Press Enter to accept                    |
| 2 · GitHub repo        | Default: Kind-Cluster-Backup-and-restore — press Enter to accept |
| 3 · Pick backup        | Shows a numbered table of all backed-up clusters with operator type — enter a number |
| 4 · Cluster name       | ✅ Auto-read from GitHub folder metadata                      |
| 5 · Operator version   | ✅ Auto-read from cnpg-version.txt                            |
| 6 · Operator namespace | ✅ Auto-read from operator-namespace.txt                      |
| 7 · Rename cluster     | Optional — press Enter to keep original name, or type a new name |
| 8 · Confirm            | Shows cluster name, operator type, version — type **Y** to proceed |

### What it does automatically

- **GitHub API list** — calls public API to list all backup folders as a numbered table
- **git clone --depth=1 with LFS** — downloads the selected backup folder including the snapshot tar
- **Read metadata** — reads operator type, version, and cluster name from metadata files
- **docker load** — loads the control-plane snapshot image into Docker
- **kind create cluster** — recreates the kind cluster from the loaded image
- **Operator install** — auto-installs the correct operator at the exact backed-up version
- **kubectl apply** — applies K8s configs + database blueprints, waits for all pods to be Ready

------

## Troubleshooting

### 🔴 Restore fails:  "Expected artifact cnpg-snapshot.tar not found"

The GitHub folder is missing the snapshot file. Git LFS was not set up when the backup was pushed. Re-run the backup on the source machine:

./docker-cluster-backup.sh

### 🔴 Backup fails: "GitHub token is invalid or expired"

Your PAT has expired or was entered incorrectly. Create a new one with repo scope at [github.com/settings/tokens](https://github.com/settings/tokens), then re-run the backup.

⚠️ Never share your PAT in chat or commit it to a file in the repo. If accidentally exposed, revoke it immediately.

### 🔴 git-lfs not found during backup or restore

\# macOS

brew install git-lfs && git lfs install

\# Ubuntu / Debian

sudo apt-get install git-lfs && git lfs install

### 🟡 Pods stuck in PodInitializing after restore

The PostgreSQL image is still pulling from ghcr.io. Wait 5–10 minutes, then verify:

kubectl get pods --context kind-<cluster> --all-namespaces

### 🔴 kind cluster name conflict on restore

The script detects this and offers to delete the existing cluster, or use the rename option at the restore prompt. To delete manually:

kind delete cluster --name <cluster>

Then re-run docker-cluster-restore.sh.

### 🟡 Restore asks for operator version manually: auto-detection failed

The cnpg-version.txt or operator-namespace.txt files are missing (backup was created by an older script version). Re-run the backup on the source machine to get a complete backup folder.

Supported namespace values: cnpg-system, postgresql-operator-system, pgd-operator-system

### 🟡 No PostgreSQL databases after restore

The cnpg-db-blueprints.yaml file was empty or missing during backup. Re-run docker-cluster-backup.sh on the source machine to regenerate the complete backup folder.
