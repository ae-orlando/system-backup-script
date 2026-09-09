#!/usr/bin/env bash
# =============================================================================
# backup-system.sh — System Configuration Backup & Restore Script
# =============================================================================
# DESCRIPTION:
#   Captures the full software configuration and user environment of a
#   Fedora Linux system into a timestamped backup directory, then generates
#   a self-contained restore-system.sh script for rebuilding the same
#   environment on a new machine.
#
# WHAT IT BACKS UP:
#   1. All RPM-installed packages (via rpm -qa)
#   2. Installed dnf package groups
#   3. Flatpak applications (system & user)
#   4. Language-specific packages: pip, npm (global), Go modules
#   5. Dotfiles (.bashrc, .zshrc, .gitconfig, .ssh, .gnupg, etc.)
#   6. Full ~/.config directory (VS Code, neovim, etc.)
#   7. Dev environment directories (.nvm, .local/bin, ~/go/bin, ~/go/pkg)
#
# OUTPUT:
#   - A timestamped directory: ~/system-backup-YYYYMMDD-HHMMSS/
#   - A compressed tarball: ~/system-backup-YYYYMMDD-HHMMSS.tar.gz
#   - A generated restore-script: <backup_dir>/restore-system.sh
#
# USAGE:
#   ./backup-system.sh
#
# RESTORE:
#   1. Copy the tarball to the target machine
#   2. tar -xzf system-backup-YYYYMMDD-HHMMSS.tar.gz
#   3. cd system-backup-YYYYMMDD-HHMMSS
#   4. bash restore-system.sh
#
# KNOWN LIMITATIONS (NOT automatically captured):
#   - Docker images & containers
#   - Docker Compose projects & named volumes
#   - VS Code extensions (with local state)
#   - Minikube clusters
#   - Custom systemd service files
#   - Python virtual environments
#   - npm/yarn/pip packages with native bindings (may need rebuilding)
#
# PLATFORM:
#   Designed for Fedora Linux (uses dnf, flatpak, rpm).
#   Requires: bash 4+, rpm, dnf, flatpak, pip, npm, go (optional)
# =============================================================================
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$HOME/system-backup-$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

echo "=== Backing up system configuration ==="
echo "Backup directory: $BACKUP_DIR"

# =============================================================================
# 1. List all installed packages via RPM
# =============================================================================
echo ""
echo "[1/6] Capturing installed packages..."
rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' > "$BACKUP_DIR/installed-packages.txt" 2>&1
echo "Found $(wc -l < "$BACKUP_DIR/installed-packages.txt") packages"

# =============================================================================
# 2. Save installed dnf groups
# =============================================================================
echo ""
echo "[2/6] Capturing dnf groups..."
dnf group list --installed > "$BACKUP_DIR/dnf-groups.txt" 2>&1 || true

# =============================================================================
# 3. List flatpaks
# =============================================================================
echo ""
echo "[3/6] Capturing flatpaks..."
flatpak list --app > "$BACKUP_DIR/flatpak-apps.txt" 2>&1 || true
flatpak list --system > "$BACKUP_DIR/flatpak-system.txt" 2>&1 || true

# =============================================================================
# 4. Capture language-specific package lists
# =============================================================================
echo ""
echo "[4/6] Capturing language-specific packages..."

# Python pip packages
pip freeze > "$BACKUP_DIR/pip-packages.txt" 2>&1 || true
echo "Pip packages saved"

# Global npm packages
npm list -g --json > "$BACKUP_DIR/npm-global-packages.json" 2>&1 || true
echo "Global npm packages saved"

# Go modules (if go installed)
if command -v go &>/dev/null; then
    go list -m all 2>/dev/null > "$BACKUP_DIR/go-modules.txt" || true
    go env GOPATH > "$BACKUP_DIR/go-env.txt" 2>&1 || true
    echo "Go environment saved"
fi

# =============================================================================
# 5. Archive dotfiles, configs, and dev environment files
# =============================================================================
echo ""
echo "[5/6] Archiving dotfiles, configs, and dev environment..."
DOTFILES_DIR="$BACKUP_DIR/dotfiles"
mkdir -p "$DOTFILES_DIR"

# Copy specific dotfiles
for f in \
    .bashrc .zshrc .profile .bash_profile .vimrc .vim .gitconfig .gitignore \
    .bash_aliases .zsh_aliases .npmrc .inputrc .curlrc .wget-hsts \
    .todo.txt .vimrc .tmux.conf .screenrc .inputrc; do
    if [ -e "$HOME/$f" ]; then
        mkdir -p "$DOTFILES_DIR/$(dirname "$f")"
        cp -r "$HOME/$f" "$DOTFILES_DIR/$f" 2>/dev/null || true
    fi
done

# Copy .ssh directory (keys, config)
if [ -d "$HOME/.ssh" ]; then
    cp -r "$HOME/.ssh" "$DOTFILES_DIR/.ssh" 2>/dev/null || true
fi

# Copy .gnupg
if [ -d "$HOME/.gnupg" ]; then
    cp -r "$HOME/.gnupg" "$DOTFILES_DIR/.gnupg" 2>/dev/null || true
fi

# Archive the entire .config directory (VS Code settings, neovim, etc.)
if [ -d "$HOME/.config" ]; then
    cp -r "$HOME/.config" "$DOTFILES_DIR/.config" 2>/dev/null || true
fi

# Archive .local/share for keyrings and recent files
for d in .local/share/keyrings .local/share/recently-used.xsl .local/share/trash; do
    if [ -e "$HOME/$d" ]; then
        mkdir -p "$DOTFILES_DIR/$(dirname "$d")"
        cp -r "$HOME/$d" "$DOTFILES_DIR/$d" 2>/dev/null || true
    fi
done

# =============================================================================
# 6. Archive dev environment directories (nvm, local bin, go)
# =============================================================================
echo ""
echo "[6/6] Archiving dev environment..."

# nvm (Node Version Manager) - captures Node.js versions AND global npm packages
if [ -d "$HOME/.nvm" ]; then
    cp -r "$HOME/.nvm" "$DOTFILES_DIR/.nvm" 2>/dev/null || true
    echo "nvm/ archived"
fi

# .local/bin - captures pip-installed binaries (poetry, oh-my-posh, etc.)
if [ -d "$HOME/.local/bin" ]; then
    cp -r "$HOME/.local/bin" "$DOTFILES_DIR/.local/bin" 2>/dev/null || true
    echo ".local/bin/ archived"
fi

# Go bin directory (go install binaries like oh-my-posh)
if [ -d "$HOME/go/bin" ]; then
    cp -r "$HOME/go/bin" "$DOTFILES_DIR/go-bin" 2>/dev/null || true
    echo "go/bin/ archived"
fi

# Go pkg directory (Go module cache)
if [ -d "$HOME/go/pkg" ]; then
    cp -r "$HOME/go/pkg" "$DOTFILES_DIR/go-pkg" 2>/dev/null || true
    echo "go/pkg/ archived"
fi

# =============================================================================
# Create the restore script
# =============================================================================
cat > "$BACKUP_DIR/restore-system.sh" << 'RESTORE_EOF'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Restoring system ==="

# Update system first
echo "[1/7] Updating system..."
sudo dnf upgrade -y

# Install all packages from the RPM list
echo ""
echo "[2/7] Installing packages..."
cat "$BACKUP_DIR/installed-packages.txt" | while read pkg; do
    sudo dnf install -y "$pkg" 2>/dev/null || echo "Warning: could not install $pkg"
done

# Install dnf groups
if [ -f "$BACKUP_DIR/dnf-groups.txt" ]; then
    echo ""
    echo "Installing dnf groups..."
    grep "^@" "$BACKUP_DIR/dnf-groups.txt" | while read group; do
        group_name=$(echo "$group" | tr -d ' ' | cut -d: -f1)
        sudo dnf group install -y "$group_name" 2>/dev/null || echo "Warning: could not install group $group_name"
    done
fi

# Install flatpaks
if [ -f "$BACKUP_DIR/flatpak-apps.txt" ]; then
    echo ""
    echo "[3/7] Installing flatpaks..."
    grep -v "^Ref" "$BACKUP_DIR/flatpak-apps.txt" | awk '{print $1}' | while read ref; do
        sudo flatpak install -y "$ref" 2>/dev/null || echo "Warning: could not install $ref"
    done
fi

# Install pip packages
if [ -f "$BACKUP_DIR/pip-packages.txt" ]; then
    echo ""
    echo "[4/7] Installing pip packages..."
    cat "$BACKUP_DIR/pip-packages.txt" | while read pkg; do
        pip install "$pkg" 2>/dev/null || echo "Warning: could not install pip package $pkg"
    done
fi

# Install global npm packages
if [ -f "$BACKUP_DIR/npm-global-packages.json" ]; then
    echo ""
    echo "[5/7] Installing global npm packages..."
    cat "$BACKUP_DIR/npm-global-packages.json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pkg in data.get('data', []):
    name = pkg.get('name', '')
    if name:
        print(name)
" 2>/dev/null | while read pkg; do
        sudo npm install -g "$pkg" 2>/dev/null || echo "Warning: could not install npm package $pkg"
    done || true
fi

# Install nvm
if [ -d "$BACKUP_DIR/dotfiles/.nvm" ]; then
    echo ""
    echo "[6/7] Restoring dev environment..."
    echo "Installing nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash 2>/dev/null || true
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    cp -r "$BACKUP_DIR/dotfiles/.nvm"/* "$NVM_DIR/" 2>/dev/null || true
    echo "nvm restored"
fi

# Restore .local/bin (pip-installed binaries)
if [ -d "$BACKUP_DIR/dotfiles/.local/bin" ]; then
    mkdir -p "$HOME/.local/bin"
    cp -r "$BACKUP_DIR/dotfiles/.local/bin/"* "$HOME/.local/bin/" 2>/dev/null || true
    echo ".local/bin restored"
fi

# Restore Go binaries
if [ -d "$BACKUP_DIR/go-bin" ]; then
    mkdir -p "$HOME/go/bin"
    cp -r "$BACKUP_DIR/go-bin/"* "$HOME/go/bin/" 2>/dev/null || true
    echo "go/bin restored"
fi

# Restore Go module cache
if [ -d "$BACKUP_DIR/go-pkg" ]; then
    mkdir -p "$HOME/go/pkg"
    cp -r "$BACKUP_DIR/go-pkg/"* "$HOME/go/pkg/" 2>/dev/null || true
    echo "go/pkg restored"
fi

# Restore .config directory
if [ -d "$BACKUP_DIR/dotfiles/.config" ]; then
    cp -r "$BACKUP_DIR/dotfiles/.config" "$HOME/.config" 2>/dev/null || true
    echo ".config restored"
fi

# Restore remaining dotfiles and configs
if [ -d "$BACKUP_DIR/dotfiles" ]; then
    echo ""
    echo "[7/7] Restoring remaining dotfiles..."
    cp -r "$BACKUP_DIR/dotfiles/.bashrc" "$HOME/.bashrc" 2>/dev/null || true
    cp -r "$BACKUP_DIR/dotfiles/.zshrc" "$HOME/.zshrc" 2>/dev/null || true
    cp -r "$BACKUP_DIR/dotfiles/.gitconfig" "$HOME/.gitconfig" 2>/dev/null || true
    cp -r "$BACKUP_DIR/dotfiles/.ssh" "$HOME/.ssh" 2>/dev/null || true
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    chmod 600 "$HOME/.ssh/id_"* 2>/dev/null || true
    echo "Dotfiles restored"
fi

# Install corepack for pnpm/yarn
if command -v corepack &>/dev/null; then
    corepack enable 2>/dev/null || true
fi

echo ""
echo "=== Restore complete! Reboot recommended. ==="
echo ""
echo "========================================================================="
echo "  MANUAL STEPS AFTER RESTORING:"
echo "========================================================================="
echo ""
echo "  1. SOURCE YOUR SHELL CONFIG:"
echo "     source ~/.bashrc || source ~/.zshrc"
echo ""
echo "  2. RELOAD NVM AND INSTALL DEFAULT NODE:"
echo "     source ~/.nvm/nvm.sh"
echo "     nvm install --lts"
echo "     nvm use --lts"
echo ""
echo "  3. ENABLE COREPACK (for pnpm/yarn):"
echo "     corepack enable"
echo ""
echo "  4. REBUILD NPM GLOBAL PACKAGES (if needed):"
echo "     npm rebuild -g"
echo ""
echo "  5. RESTORE DOCKER IMAGES (NOT AUTOMATICALLY CAPTURED):"
echo "     docker load < docker-images.tar"
echo "     cat docker-containers.tar | docker import -"
echo ""
echo "  6. RESTORE VS CODE EXTENSIONS:"
echo "     Open VS Code -> Extensions view -> install missing extensions"
echo "     Or use Settings Sync: Cmd+Shift+P -> 'Settings Sync: Turn On'"
echo ""
echo "  7. RESTORE MINIKUBE (NOT AUTOMATICALLY CAPTURED):"
echo "     minikube start --memory=4096 --cpus=2"
echo ""
echo "  8. RESTORE CUSTOM SYSTEMD SERVICES (NOT AUTOMATICALLY CAPTURED):"
echo "     sudo cp *.service /etc/systemd/system/"
echo "     sudo systemctl daemon-reload"
echo "     sudo systemctl enable <service>"
echo ""
echo "========================================================================="
RESTORE_EOF

chmod +x "$BACKUP_DIR/restore-system.sh"

# Create a single compressed tarball
echo ""
echo "=== Creating compressed backup ==="
tar -czf "$HOME/system-backup-$TIMESTAMP.tar.gz" "$BACKUP_DIR" 2>/dev/null

echo ""
echo "=== Backup complete! ==="
echo "All files saved to: $BACKUP_DIR"
echo "Compressed archive: $HOME/system-backup-$TIMESTAMP.tar.gz"
echo ""
echo "To restore on a new system:"
echo "  1. Copy the tarball to the new system"
echo "  2. Extract: tar -xzf system-backup-$TIMESTAMP.tar.gz"
echo "  3. cd into the backup directory"
echo "  4. Run: bash restore-system.sh"
echo ""
echo "Alternatively, just copy these files manually:"
echo "  - installed-packages.txt"
echo "  - dnf-groups.txt"
echo "  - flatpak-apps.txt"
echo "  - pip-packages.txt"
echo "  - npm-global-packages.json"
echo "  - dotfiles/ directory"
echo "  - restore-system.sh"
echo ""
echo "Or simply extract the tarball and run: bash restore-system.sh"
echo ""
echo "========================================================================="
echo "  ITEMS THIS SCRIPT CANNOT AUTOMATICALLY CAPTURE (manual steps needed):"
echo "========================================================================="
echo ""
echo "  1. DOCKER IMAGES & CONTAINERS"
echo "     ----------------------------"
echo "     This script does NOT back up Docker images or containers."
echo "     To manually back up BEFORE running this script:"
echo "       docker save \$(docker images -q) > docker-images.tar"
echo "       docker export \$(docker ps -q) > docker-containers.tar"
echo "     To restore on new system:"
echo "       docker load < docker-images.tar"
echo "       cat docker-containers.tar | docker import -"
echo ""
echo "  2. DOCKER COMPOSE PROJECTS & VOLUMES"
echo "     ----------------------------"
echo "     Docker Compose projects and named volumes are NOT captured."
echo "     To manually back up:"
echo "       cp -r /path/to/compose/projects \$BACKUP_DIR/"
echo "       docker cp <container>:/path /backup/path"
echo "     Restore by copying files back and running docker-compose up."
echo ""
echo "  3. VS CODE EXTENSIONS (with local state)"
echo "     ----------------------------"
echo "     VS Code settings in .config/Code/User/ are captured,"
echo "     but some extensions with local cache/state are not fully portable."
echo "     Recommended: Enable VS Code Settings Sync:"
echo "       In VS Code: Cmd+Shift+P -> 'Settings Sync: Turn On'"
echo "     Or manually copy extensions:"
echo "       cp -r ~/.config/Code/User/extensions \$BACKUP_DIR/"
echo ""
echo "  4. MINIKUBE CLUSTERS"
echo "     ----------------------------"
echo "     Minikube clusters are NOT captured."
echo "     To manually export:"
echo "       minikube export > minikube-state.json"
echo "     To restore: minikube start --memory=4096 --cpus=2"
echo ""
echo "  5. CUSTOM SYSTEMD SERVICES"
echo "     ----------------------------"
echo "     Custom service files in /etc/systemd/system/ are NOT captured."
echo "     To manually back up:"
echo "       sudo cp /etc/systemd/system/*.service \$BACKUP_DIR/systemd-services/"
echo "     To restore on new system:"
echo "       sudo cp *.service /etc/systemd/system/"
echo "       sudo systemctl daemon-reload"
echo "       sudo systemctl enable <service>"
echo ""
echo "  6. NPM/YARN/PIP GLOBAL PACKAGES WITH NATIVE BINDINGS"
echo "     ----------------------------"
echo "     Some packages with native bindings (node-gyp, etc.) may need rebuilding."
echo "     After restore, run: npm rebuild -g"
echo ""
echo "  7. PYTHON VIRTUAL ENVIRONMENTS"
echo "     ----------------------------"
echo "     Python venv directories are NOT captured (too large)."
echo "     Use pip freeze to record packages, then recreate:"
echo "       python -m venv /path/to/venv"
echo "       source /path/to/venv/bin/activate"
echo "       pip install -r requirements.txt"
echo ""
echo "========================================================================="
echo "  AFTER RESTORING, RUN THESE COMMANDS:"
echo "========================================================================="
echo "  source ~/.bashrc || source ~/.zshrc"
echo "  source ~/.nvm/nvm.sh"
echo "  nvm install --lts"
echo "  nvm use --lts"
echo "  corepack enable"
echo "  go install github.com/JanDeDobbeleer/oh-my-posh@latest 2>/dev/null || true"
echo "  sudo dnf group install 'Development Tools' 2>/dev/null || true"
echo "  sudo dnf install kernel-devel kernel-headers 2>/dev/null || true"
echo "========================================================================="
echo ""
echo ""
echo "========================================================================="
echo "  ITEMS THIS SCRIPT CANNOT AUTOMATICALLY CAPTURE (manual steps needed):"
echo "========================================================================="
echo ""
echo "  1. DOCKER IMAGES & CONTAINERS"
echo "     ----------------------------"
echo "     This script does NOT back up Docker images or containers."
echo "     To manually back up BEFORE running this script:"
echo "       docker save \$(docker images -q) > docker-images.tar"
echo "       docker export \$(docker ps -q) > docker-containers.tar"
echo "     To restore on new system:"
echo "       docker load < docker-images.tar"
echo "       cat docker-containers.tar | docker import -"
echo ""
echo "  2. DOCKER COMPOSE PROJECTS & VOLUMES"
echo "     ----------------------------"
echo "     Docker Compose projects and named volumes are NOT captured."
echo "     To manually back up BEFORE running this script:"
echo "       cp -r /path/to/compose/projects \$BACKUP_DIR/"
echo "       docker cp <container>:/path /backup/path"
echo "     Restore by copying files back and running docker-compose up."
echo ""
echo "  3. VS CODE EXTENSIONS (with local state)"
echo "     ----------------------------"
echo "     VS Code settings in .config/Code/User/ are captured,"
echo "     but some extensions with local cache/state are not fully portable."
echo "     Recommended: Enable VS Code Settings Sync:"
echo "       In VS Code: Cmd+Shift+P -> 'Settings Sync: Turn On'"
echo "     Or manually copy extensions:"
echo "       cp -r ~/.config/Code/User/extensions \$BACKUP_DIR/"
echo ""
echo "  4. MINIKUBE CLUSTERS"
echo "     ----------------------------"
echo "     Minikube clusters are NOT captured."
echo "     To manually export BEFORE running this script:"
echo "       minikube export > minikube-state.json"
echo "     To restore: minikube start --memory=4096 --cpus=2"
echo ""
echo "  5. CUSTOM SYSTEMD SERVICES"
echo "     ----------------------------"
echo "     Custom service files in /etc/systemd/system/ are NOT captured."
echo "     To manually back up BEFORE running this script:"
echo "       sudo cp /etc/systemd/system/*.service \$BACKUP_DIR/systemd-services/"
echo "     To restore on new system:"
echo "       sudo cp *.service /etc/systemd/system/"
echo "       sudo systemctl daemon-reload"
echo "       sudo systemctl enable <service>"
echo ""
echo "  6. PYTHON VIRTUAL ENVIRONMENTS"
echo "     ----------------------------"
echo "     Python venv directories are NOT captured (too large)."
echo "     Use pip freeze to record packages, then recreate venvs:"
echo "       python -m venv /path/to/venv"
echo "       source /path/to/venv/bin/activate"
echo "       pip install -r requirements.txt"
echo ""
echo "========================================================================="
echo "  AFTER RESTORING, RUN THESE COMMANDS:"
echo "========================================================================="
echo "  source ~/.bashrc || source ~/.zshrc"
echo "  source ~/.nvm/nvm.sh"
echo "  nvm install --lts"
echo "  nvm use --lts"
echo "  corepack enable"
echo "  go install github.com/JanDeDobbeleer/oh-my-posh@latest 2>/dev/null || true"
echo "  sudo dnf group install 'Development Tools' 2>/dev/null || true"
echo "  sudo dnf install kernel-devel kernel-headers 2>/dev/null || true"
echo "========================================================================="
