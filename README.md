# System Backup & Restore Script

A Bash script that captures the full software configuration and user environment of a **Fedora Linux** system into a timestamped backup directory, and generates a self-contained restore script for rebuilding the same environment on a new machine.

## Overview

- **Backup script:** `backup-system.sh` — runs on the source machine
- **Generated restore script:** `restore-system.sh` — auto-generated inside each backup, runs on the target machine
- **Output format:** Timestamped directory + compressed `.tar.gz` archive

## What It Backs Up

| Category | Details |
|---|---|
| **RPM Packages** | All installed packages via `rpm -qa` |
| **DNF Groups** | Installed package groups (e.g., "Development Tools") |
| **Flatpaks** | System and user Flatpak applications |
| **Python (pip)** | All pip-installed packages |
| **Node.js (npm)** | Global npm packages |
| **Go** | Go modules list, GOPATH, binaries, and module cache |
| **Dotfiles** | `.bashrc`, `.zshrc`, `.gitconfig`, `.ssh`, `.gnupg`, `.vimrc`, `.tmux.conf`, `.inputrc`, and more |
| **VS Code & Configs** | Full `~/.config` directory (VS Code settings, neovim, etc.) |
| **Keyrings & State** | `.local/share/keyrings`, `.local/share/recently-used.xsl`, `.local/share/trash` |
| **nvm** | Node Version Manager directory (captures Node versions + global npm packages) |
| **Local Binaries** | `~/.local/bin` (pip-installed tools like poetry, oh-my-posh) |
| **Go Binaries & Cache** | `~/go/bin` and `~/go/pkg` |

## What It Does NOT Capture (Manual Steps Required)

The following are **not** automatically backed up. You must handle these separately:

1. **Docker Images & Containers**
   ```bash
   docker save $(docker images -q) > docker-images.tar
   docker export $(docker ps -q) > docker-containers.tar
   ```

2. **Docker Compose Projects & Named Volumes**
   - Manually copy compose project directories and use `docker cp` for volumes.

3. **VS Code Extensions (with local state)**
   - Settings are captured in `~/.config/Code/User/`, but extensions with local cache/state are not fully portable.
   - **Recommendation:** Enable VS Code Settings Sync (`Cmd+Shift+P` → "Settings Sync: Turn On").

4. **Minikube Clusters**
   ```bash
   minikube export > minikube-state.json
   ```

5. **Custom Systemd Services**
   ```bash
   sudo cp /etc/systemd/system/*.service $BACKUP_DIR/systemd-services/
   ```

6. **Python Virtual Environments**
   - Venv directories are too large to capture. Recreate from `pip freeze` output.

7. **npm/yarn/pip Packages with Native Bindings**
   - Packages compiled with native extensions (e.g., `node-gyp`) may need rebuilding after restore.

## Prerequisites

- **OS:** Fedora Linux (tested on recent Fedora releases)
- **Shell:** Bash 4+
- **Required tools:** `bash`, `rpm`, `dnf`, `flatpak`, `pip`, `npm`
- **Optional tools:** `go`, `nvm` (script gracefully skips if absent)
- **Permissions:** Run normally for most items. `sudo` is used inside `restore-system.sh` for package installation.

## Usage

### Backup

```bash
./backup-system.sh
```

This will:
1. Create a timestamped directory: `~/system-backup-YYYYMMDD-HHMMSS/`
2. Populate it with all captured data and a generated `restore-system.sh`
3. Create a compressed archive: `~/system-backup-YYYYMMDD-HHMMSS.tar.gz`

### Restore

On a **fresh Fedora system**:

```bash
# Copy the tarball to the new machine
tar -xzf system-backup-YYYYMMDD-HHMMSS.tar.gz
cd system-backup-YYYYMMDD-HHMMSS
bash restore-system.sh
```

Or simply copy the backup directory and run `restore-system.sh` from within it.

## After Restore — Mandatory Steps

The restore script completes with these manual steps you **must** perform:

```bash
# 1. Source your shell config
source ~/.bashrc || source ~/.zshrc

# 2. Reload nvm and install default Node
source ~/.nvm/nvm.sh
nvm install --lts
nvm use --lts

# 3. Enable corepack (for pnpm/yarn)
corepack enable

# 4. Rebuild npm global packages (if needed)
npm rebuild -g

# 5. Restore Docker images
docker load < docker-images.tar
cat docker-containers.tar | docker import -

# 6. Restore VS Code extensions
#    Open VS Code → Extensions view → install missing extensions
#    Or use Settings Sync

# 7. Restore Minikube
minikube start --memory=4096 --cpus=2

# 8. Restore custom systemd services
sudo cp *.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable <service>

# 9. Post-setup extras
go install github.com/JanDeDobbeleer/oh-my-posh@latest 2>/dev/null || true
sudo dnf group install 'Development Tools' 2>/dev/null || true
sudo dnf install kernel-devel kernel-headers 2>/dev/null || true
```

## Output Structure

```
system-backup-YYYYMMDD-HHMMSS/
├── installed-packages.txt      # Full RPM package list
├── dnf-groups.txt              # Installed dnf groups
├── flatpak-apps.txt            # Flatpak applications
├── flatpak-system.txt          # System flatpaks
├── pip-packages.txt            # Python pip packages
├── npm-global-packages.json    # Global npm packages
├── go-modules.txt              # Go module list
├── go-env.txt                  # Go environment info
├── restore-system.sh           # Auto-generated restore script
├── dotfiles/
│   ├── .bashrc, .zshrc, .gitconfig, ...
│   ├── .ssh/                   # SSH keys and config
│   ├── .gnupg/                 # GPG keys
│   ├── .config/                # VS Code, neovim, etc.
│   ├── .nvm/                   # Node Version Manager
│   ├── .local/bin/             # Pip-installed binaries
│   └── ...
├── go-bin/                     # Go installed binaries
├── go-pkg/                     # Go module cache
└── system-backup-YYYYMMDD-HHMMSS.tar.gz  # Compressed archive
```

## Customization

The script is designed to be easily modified. Key areas to customize:

- **Additional dotfiles:** Add filenames to the loop in section 5 (line ~64)
- **Additional directories to back up:** Add `cp -r` commands in section 6
- **Pre/post backup hooks:** Add commands before the `# Create the restore script` marker
- **Restore steps:** Edit the heredoc block that generates `restore-system.sh`

## License

Free to use and modify as needed.
