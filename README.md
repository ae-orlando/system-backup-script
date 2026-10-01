# Fedora Dev Machine Toolkit

Two complementary Bash scripts for Fedora Linux: one builds a fresh Fedora Workstation into a polyglot dev environment, the other backs that machine up and restores it elsewhere.

| Script | Purpose | Docs |
|---|---|---|
| `setup-fedora-dev.sh` | Fresh install → dev environment (repos, toolchains, zsh + p10k, kitty, containers). Idempotent | [`FEDORA-DEV-SETUP.md`](FEDORA-DEV-SETUP.md) |
| `backup-system.sh` | Running machine → timestamped backup + generated `restore-system.sh` | This README (below) |

Typical lifecycle: **set up** a new machine → **back it up** → **restore** on the next machine → **re-run setup** to converge.

## Quickstart

```bash
# 1. Build the environment (fresh Fedora Workstation, ~15-30 min)
chmod +x setup-fedora-dev.sh
./setup-fedora-dev.sh --dry-run   # preview, changes nothing
./setup-fedora-dev.sh
# then: log out/in, open kitty, run `p10k configure` if prompted

# 2. Back it up
./backup-system.sh                    # → ~/system-backup-YYYYMMDD-HHMMSS/
./backup-system.sh /path/to/backup    # → custom root

# 3. Restore on another machine
tar -xzf system-backup-YYYYMMDD-HHMMSS.tar.gz
cd system-backup-YYYYMMDD-HHMMSS
bash restore-system.sh
```

## Setup script at a glance

`setup-fedora-dev.sh` is fully automated and idempotent (safe to re-run; only gaps are filled):

- Pre-flight (Fedora check, network, ≥ 20 GB disk, sudo once, snapper/timeshift snapshot) with exit codes `0/1/2`
- DNF tuning, full upgrade, RPM Fusion, OpenH264, Flathub
- Build tools, modern CLI set, neovim, kitty (Catppuccin Mocha, JetBrainsMono Nerd 13)
- User-space runtimes: fnm + Node LTS, uv + pyenv, rustup, Go, OpenJDK (optional SDKMAN!, Docker CE)
- Podman stack, KVM/libvirt, Oh My Zsh + Powerlevel10k with zsh as default shell
- Flags: `--docker --sdkman --skip-upgrade --only <sections> --dry-run -y -v` (all with env equivalents)

See [`FEDORA-DEV-SETUP.md`](FEDORA-DEV-SETUP.md) for the full flag reference, `--only` tokens, post-install checklist, and troubleshooting.

---

# System Backup & Restore

`backup-system.sh` captures the full software configuration and user environment into a timestamped backup directory, then generates a self-contained `restore-system.sh` for rebuilding the same environment on a new machine.

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

### Backup script

- **OS:** Fedora Linux (tested on recent Fedora releases)
- **Shell:** Bash 4+
- **Required tools:** `bash`, `rpm`, `dnf`, `flatpak`, `pip`, `npm`
- **Optional tools:** `go`, `nvm` (script gracefully skips if absent)
- **Permissions:** Run normally for most items. `sudo` is used inside `restore-system.sh` for package installation.

### Setup script

- Fedora Workstation, a regular user with `sudo` rights (never root), internet, ≥ 20 GB free disk. Details in [`FEDORA-DEV-SETUP.md`](FEDORA-DEV-SETUP.md).

## Usage

### Backup

```bash
./backup-system.sh                    # Backs up to ~/system-backup-YYYYMMDD-HHMMSS/
./backup-system.sh /path/to/backup    # Backs up to /path/to/backup/system-backup-YYYYMMDD-HHMMSS/
```

If no argument is provided, it defaults to `$HOME`.

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

> Tip: after restoring, re-run `./setup-fedora-dev.sh` to converge anything the backup doesn't cover (fresh toolchains, shell wiring, verification).

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

The backup script is designed to be easily modified. Key areas to customize:

- **Additional dotfiles:** Add filenames to the loop in section 5 (line ~64)
- **Additional directories to back up:** Add `cp -r` commands in section 6
- **Pre/post backup hooks:** Add commands before the `# Create the restore script` marker
- **Restore steps:** Edit the heredoc block that generates `restore-system.sh`

## License

Free to use and modify as needed.
