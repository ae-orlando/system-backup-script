#!/usr/bin/env bash
# =============================================================================
# setup-fedora-dev.sh — Fedora Workstation → Ultimate Polyglot Dev Environment
# =============================================================================
# DESCRIPTION:
#   Transforms a fresh Fedora Workstation installation into a production-grade,
#   polyglot development environment. Fully automated and idempotent: safe to
#   re-run any time; every step checks for existing state before changing it.
#
# WHAT IT DOES:
#   1. Pre-flight checks (OS, network, disk, sudo, snapshot)
#   2. DNF/DNF5 tuning + full system upgrade
#   3. Enables RPM Fusion (Free/Non-Free), Cisco OpenH264, Flathub
#   4. Installs build essentials, modern CLI toolkit, neovim + kitty
#   5. Installs polyglot runtimes in user space (fnm/node, uv/pyenv,
#      rustup, go, JDK/sdkman)
#   6. Installs podman stack, optional Docker CE, KVM/libvirt stack
#   7. Zsh + Oh My Zsh + Powerlevel10k (dev plugins, zsh default shell,
#      interactive `p10k configure`) + idempotent PATH/completion wiring
#      for ~/.bashrc & ~/.zshrc
#   8. Verification + post-install report
#
# USAGE:
#   ./setup-fedora-dev.sh [OPTIONS]
#
# OPTIONS:
#   -y, --yes        Non-interactive (assume yes where prompted; still
#                    prompts for sudo password once if needed).
#                    NOTE: skips the 'p10k configure' wizard and the
#                    'chsh' default-shell switch (printed as follow-ups).
#   --docker         Install Docker CE and add user to docker group
#   --no-docker      Skip Docker CE (default)
#   --sdkman         Also install SDKMAN! in user space
#   --no-sdkman      Skip SDKMAN! (default)
#   --skip-upgrade   Skip the full 'dnf upgrade --refresh' (fast re-runs)
#   --only a,b       Run only these sections (comma-separated):
#                    tune,upgrade,repos,build,cli,editors,kitty,zsh,
#                    node,python,rust,go,java,containers,virt,shells
#                    (pre-flight, verification and summary always run)
#   --dry-run        Print what would run without changing anything
#   -v, --verbose    Trace execution (set -x) for debugging
#   -h, --help       Show this help and exit
#
# ENV FLAGS (alternative to CLI flags):
#   INSTALL_DOCKER=1  same as --docker   (default: 0)
#   INSTALL_SDKMAN=1  same as --sdkman   (default: 0)
#   NONINTERACTIVE=1  same as --yes      (default: 0)
#   SKIP_UPGRADE=1    same as --skip-upgrade (default: 0)
#   ONLY=a,b          same as --only (default: all sections)
#   DRY_RUN=1         same as --dry-run (default: 0)
#   VERBOSE=1         same as --verbose (default: 0)
#   FLATPAK_APPS="id1 id2"  optional Flatpak app IDs to install (default: none)
#   NERD_FONTS_REF=master   git ref for JetBrainsMono Nerd Font downloads
#
# EXAMPLES:
#   ./setup-fedora-dev.sh
#   INSTALL_DOCKER=1 ./setup-fedora-dev.sh -y
#   ./setup-fedora-dev.sh --docker --sdkman
#   ./setup-fedora-dev.sh --skip-upgrade
#   ./setup-fedora-dev.sh --only kitty,zsh
#   ./setup-fedora-dev.sh --dry-run
#
# REQUIREMENTS:
#   - Run as a REGULAR user with sudo privileges (NEVER as root).
#   - Fedora Workstation, active internet, >= 20 GB free disk.
#   - bash 4+, curl, sudo, dnf/dnf5.
#
# IDEMPOTENCY:
#   Every install/mutation is guarded (rpm -q, command -v, grep -Fxq,
#   flatpak remote-list, systemctl is-enabled, id -nG, etc.).
#
# EXIT CODES:
#   0 success, 1 pre-flight failure, 2 privilege misuse.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals & defaults (env-overridable)
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
LOG_FILE="${LOG_FILE:-$HOME/fedora-dev-setup.log}"
INSTALL_DOCKER="${INSTALL_DOCKER:-0}"
INSTALL_SDKMAN="${INSTALL_SDKMAN:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
MIN_DISK_GB="${MIN_DISK_GB:-20}"
SKIP_UPGRADE="${SKIP_UPGRADE:-0}"
ONLY="${ONLY:-}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"
FLATPAK_APPS="${FLATPAK_APPS:-}"
NERD_FONTS_REF="${NERD_FONTS_REF:-master}"
FEDORA_VERSION="$(rpm -E %fedora 2>/dev/null || echo "")"

# Ordered install sections (tokens for --only). Verification/summary always run.
_STEPS=(
  "tune:DNF tuning (/etc/dnf/dnf.conf)"
  "upgrade:Full system upgrade"
  "repos:Repositories (RPM Fusion, OpenH264, Flathub)"
  "build:Build essentials"
  "cli:Modern CLI toolkit"
  "editors:Neovim + kitty packages"
  "kitty:Kitty config (Catppuccin, JetBrainsMono NF, default terminal)"
  "zsh:Zsh + Oh My Zsh + Powerlevel10k"
  "node:Node.js via fnm"
  "python:Python via uv + pyenv"
  "rust:Rust via rustup"
  "go:Go toolchain"
  "java:Java (OpenJDK, optional SDKMAN!)"
  "containers:Podman stack (optional Docker CE)"
  "virt:Virtualization (KVM/libvirt)"
  "shells:Shell PATH + completion wiring"
)
VALID_ONLY_TOKENS="tune upgrade repos build cli editors kitty zsh node python rust go java containers virt shells"

# Detect package manager: prefer dnf5 on Fedora >= 41, fall back to dnf.
DNF_CMD="dnf"
if command -v dnf5 &>/dev/null; then
  DNF_CMD="dnf5"
elif command -v dnf &>/dev/null; then
  DNF_CMD="dnf"
fi

# ---------------------------------------------------------------------------
# Trap handler — log line numbers on unexpected exits
# ---------------------------------------------------------------------------
cleanup() {
  # Kill sudo keep-alive loop if running.
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
}
on_error() {
  local exit_code=$?
  local line_no="${1:-?}"
  log_error "Unexpected failure (exit=${exit_code}) at line ${line_no}. See ${LOG_FILE} for details."
  cleanup
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Logging & UX (color-coded, TTY-aware, mirrored to LOG_FILE)
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _C_RESET='\033[0m'; _C_BLUE='\033[1;34m'; _C_YELLOW='\033[1;33m'
  _C_RED='\033[1;31m'; _C_GREEN='\033[1;32m'; _C_DIM='\033[2m'
else
  _C_RESET=''; _C_BLUE=''; _C_YELLOW=''; _C_RED=''; _C_GREEN=''; _C_DIM=''
fi

_log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%b\n' "${_C_DIM}[${ts}]${_C_RESET} ${level} ${msg}" >&2
  printf '[%s] %s\n' "$ts" "$(printf '%s' "${level} ${msg}" | sed 's/\x1b\[[0-9;]*m//g')" >>"$LOG_FILE" 2>/dev/null || true
}
log_info()    { _log "${_C_BLUE}[INFO]${_C_RESET}"    "$@"; }
log_warn()    { _log "${_C_YELLOW}[WARN]${_C_RESET}"   "$@"; }
log_error()   { _log "${_C_RED}[ERROR]${_C_RESET}"    "$@"; }
log_success() { _log "${_C_GREEN}[OK]${_C_RESET}"     "$@"; }

section() {
  local title="$1"
  printf '\n%b\n' "${_C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_C_RESET}" >&2
  printf '%b\n' "${_C_BLUE}▶ ${title}${_C_RESET}" >&2
  printf '%b\n' "${_C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_C_RESET}" >&2
  printf '[%s] === %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$title" >>"$LOG_FILE" 2>/dev/null || true
}

usage() {
  # Print header comment block (lines 2 through 3rd '# ===' delimiter).
  awk 'NR>=2{print} /^# ={5,}/{n++; if(n==3) exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# CLI parsing (keeps ENV defaults)
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) NONINTERACTIVE=1; shift ;;
      --docker) INSTALL_DOCKER=1; shift ;;
      --no-docker) INSTALL_DOCKER=0; shift ;;
      --sdkman) INSTALL_SDKMAN=1; shift ;;
      --no-sdkman) INSTALL_SDKMAN=0; shift ;;
      --skip-upgrade) SKIP_UPGRADE=1; shift ;;
      --only)
        if [[ $# -lt 2 ]]; then log_error "--only requires a value (see --help)"; exit 1; fi
        ONLY="$2"; shift 2 ;;
      --only=*) ONLY="${1#--only=}"; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log_error "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
  done
}

# True when section $1 should run (all when ONLY is empty).
should_run() {
  if [[ -z "${ONLY// /}" ]]; then
    return 0
  fi
  local item
  local IFS=','
  read -ra _only_tokens <<< "$ONLY"
  for item in "${_only_tokens[@]}"; do
    if [[ "${item// /}" == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

validate_only() {
  if [[ -z "${ONLY// /}" ]]; then
    return 0
  fi
  local item
  local IFS=','
  read -ra _only_tokens <<< "$ONLY"
  for item in "${_only_tokens[@]}"; do
    item="${item// /}"
    if [[ -z "$item" ]]; then
      continue
    fi
    # shellcheck disable=SC2086
    if [[ " $VALID_ONLY_TOKENS " != *" $item "* ]]; then
      log_error "Unknown --only section: '$item'. Valid: $VALID_ONLY_TOKENS"
      exit 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Idempotency helpers
# ---------------------------------------------------------------------------
command_exists() { command -v "$1" &>/dev/null; }

rpm_is_installed() { rpm -q "$1" &>/dev/null; }

dnf_group_installed() {
  # Usage: dnf_group_installed "Development Tools" | "C Development"
  # Anchored match so similarly-named groups can't false-positive.
  sudo "$DNF_CMD" group list --installed 2>/dev/null | grep -qiE "^[[:space:]]*${1}[[:space:]]*$"
}

# Install only missing RPM packages. Usage: ensure_dnf_packages pkg1 pkg2 ...
ensure_dnf_packages() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    # Skip group specs (start with @) — handled separately.
    [[ "$pkg" == @* ]] && continue
    if ! rpm_is_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log_info "All RPM packages already installed: $*"
    return 0
  fi
  log_info "Installing missing RPM packages: ${missing[*]}"
  # shellcheck disable=SC2086
  sudo "$DNF_CMD" install -y "${missing[@]}"
}

ensure_dnf_group() {
  local group="$1"
  if dnf_group_installed "$group"; then
    log_info "DNF group already installed: '${group}'"
  else
    log_info "Installing DNF group: '${group}'"
    sudo "$DNF_CMD" group install -y "$group"
  fi
}

# Append an exact line to a file only if it is not already present.
# Usage: ensure_line_in_file "line content" /path/to/file
ensure_line_in_file() {
  local line="$1" file="$2"
  touch "$file"
  if grep -Fxq -- "$line" "$file"; then
    return 0
  fi
  printf '%s\n' "$line" >>"$file"
}

# Ensure a managed block exists between markers in a shell rc file.
# Re-running replaces the block instead of duplicating it.
ensure_managed_block() {
  local file="$1" block_content="$2"
  local begin="# >>> fedora-dev-setup >>>"
  local end="# <<< fedora-dev-setup <<<"
  touch "$file"
  local tmp
  tmp="$(mktemp)"
  # Remove any previous managed block, keep everything else byte-identical.
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    !skip { print }
  ' "$file" >"$tmp"
  {
    cat "$tmp"
    printf '%s\n' "$begin" "$block_content" "$end"
  } >"$file"
  rm -f "$tmp"
}

confirm() {
  # confirm "prompt" → 0=yes. Auto-yes when NONINTERACTIVE=1.
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    return 0
  fi
  local prompt="$1"
  local ans
  read -r -p "$prompt [Y/n] " ans
  [[ -z "${ans:-}" || "$ans" =~ ^[Yy]$ ]]
}

# Keep a one-time baseline backup before editing user files.
# The FIRST run's original is preserved; later runs never overwrite it.
backup_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  local bak="${file}.pre-fedora-dev.bak"
  if [[ -f "$bak" ]]; then
    return 0
  fi
  cp -p "$file" "$bak" && log_info "Backed up ${file} → ${bak}"
}

# Download a URL to dest with retries. Skips existing non-empty files,
# removes partial/empty output, and returns nonzero on failure WITHOUT
# printing attacker-influenced content. Safe to use in `if` conditions.
fetch_file() {
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then
    return 0
  fi
  local tmp="${dest}.part.$$"
  rm -f "$tmp"
  if curl -fsSL --retry 3 --max-time 120 -o "$tmp" "$url" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$dest"
    return 0
  fi
  rm -f "$tmp" "$dest"
  return 1
}

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
preflight_privilege_check() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    log_error "Do NOT run this script directly as root. Run as a regular user with sudo privileges."
    exit 2
  fi
  if ! sudo -n true 2>/dev/null; then
    log_info "Administrator privileges required. Prompting for sudo password once…"
    sudo -v || { log_error "sudo authentication failed."; exit 2; }
  fi
  # Keep sudo timestamp alive in background; killed via trap on exit.
  ( while true; do sudo -n true 2>/dev/null || true; sleep 50; kill -0 $$ 2>/dev/null || exit 0; done ) &
  SUDO_KEEPALIVE_PID=$!
  log_success "Privilege check passed (sudo keep-alive PID ${SUDO_KEEPALIVE_PID})."
}

preflight_os_check() {
  section "Pre-flight: operating system"
  if [[ ! -f /etc/os-release ]]; then
    log_error "/etc/os-release not found — cannot verify OS."
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "fedora" ]]; then
    log_error "Unsupported OS: '${NAME:-unknown}' (ID='${ID:-?}'). This script requires Fedora Workstation."
    exit 1
  fi
  if [[ "${VARIANT_ID:-}" == "workstation" ]] || [[ "${VARIANT:-}" == *"Workstation"* ]]; then
    log_success "OS verified: ${PRETTY_NAME:-Fedora Workstation}."
  else
    log_warn "OS is Fedora but variant is '${VARIANT:-${VARIANT_ID:-unknown}}', not 'Workstation'. Continuing (repositories are identical across Fedora editions)."
  fi
  if [[ -z "$FEDORA_VERSION" ]]; then
    log_warn "Could not determine Fedora release number; RPM Fusion URLs may need manual review."
  else
    log_info "Fedora release: ${FEDORA_VERSION} | package manager: ${DNF_CMD}."
  fi
}

preflight_network_check() {
  section "Pre-flight: internet connectivity"
  local ok=0
  if command_exists curl; then
    if curl -fsSL --max-time 15 -o /dev/null https://fedoraproject.org/; then
      ok=1
    fi
  elif command_exists wget; then
    if wget -q --timeout=15 -O /dev/null https://fedoraproject.org/; then
      ok=1
    fi
  else
    # Fallback: Python stdlib (always present on Fedora Workstation).
    if python3 -c "import urllib.request; urllib.request.urlopen('https://fedoraproject.org/', timeout=15)" 2>/dev/null; then
      ok=1
    fi
  fi
  if [[ "$ok" -ne 1 ]]; then
    # Last resort: ICMP.
    if ping -c1 -W5 8.8.8.8 &>/dev/null; then
      ok=1
    fi
  fi
  if [[ "$ok" -ne 1 ]]; then
    log_error "No active internet connectivity detected. Connect and re-run."
    exit 1
  fi
  log_success "Internet connectivity confirmed."
}

preflight_disk_check() {
  section "Pre-flight: disk space"
  local avail_kb avail_gb
  avail_kb="$(df --output=avail -k / | tail -n1 | tr -d ' ')"
  avail_gb=$((avail_kb / 1024 / 1024))
  log_info "Free disk space on /: ${avail_gb} GiB (required: ${MIN_DISK_GB} GiB)."
  if [[ "$avail_gb" -lt "$MIN_DISK_GB" ]]; then
    log_error "Insufficient disk space: ${avail_gb} GiB < ${MIN_DISK_GB} GiB required."
    exit 1
  fi
  log_success "Disk space check passed."
}

preflight_snapshot() {
  section "Pre-flight: system snapshot (if available)"
  if command_exists snapper; then
    # list-configs prints a header row; only data rows (NR>1) count as configs.
    if sudo snapper list-configs 2>/dev/null | awk 'NR>1 && NF' | grep -q .; then
      log_info "Creating snapper pre-setup snapshot…"
      sudo snapper create --description "pre-fedora-dev-setup $(date '+%F %T')" --cleanup-algorithm number \
        && log_success "Snapper snapshot created." \
        || log_warn "Snapper snapshot failed; continuing anyway."
    else
      log_warn "snapper installed but no configs found; skipping snapshot (run 'sudo snapper create-config /' first)."
    fi
    return 0
  fi
  if command_exists timeshift; then
    log_info "Creating Timeshift snapshot (this may take a while)…"
    sudo timeshift --create --comments "pre-fedora-dev-setup $(date '+%F %T')" --scripted \
      && log_success "Timeshift snapshot created." \
      || log_warn "Timeshift snapshot failed; continuing anyway."
    return 0
  fi
  log_info "Neither snapper nor timeshift installed — skipping snapshot. (Install one for rollback safety: 'sudo dnf install snapper'.)"
}

run_preflight() {
  preflight_privilege_check
  preflight_os_check
  preflight_network_check
  preflight_disk_check
  preflight_snapshot
}

# ---------------------------------------------------------------------------
# 2. System optimizations & repositories
# ---------------------------------------------------------------------------
tune_dnf() {
  section "DNF tuning (/etc/dnf/dnf.conf)"
  local conf="/etc/dnf/dnf.conf"
  sudo touch "$conf"
  sudo_crud_ini "$conf" "max_parallel_downloads" "10"
  sudo_crud_ini "$conf" "fastestmirror" "True"
  log_success "DNF tuning applied."
}

# Idempotently set key=value under [main] in a sudo-owned ini file.
sudo_crud_ini() {
  local file="$1" key="$2" value="$3"
  if sudo grep -qE "^${key}=" "$file" 2>/dev/null; then
    if sudo grep -qE "^${key}=${value}$" "$file"; then
      log_info "${file}: ${key}=${value} already set."
      return 0
    fi
    sudo sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
    log_info "${file}: updated ${key}=${value}."
  else
    # Ensure a [main] header exists (dnf.conf convention).
    if ! sudo grep -qE "^\[main\]" "$file"; then
      sudo sh -c "printf '[main]\n' | cat - '$file' > '${file}.new' && mv '${file}.new' '$file'"
    fi
    echo "${key}=${value}" | sudo tee -a "$file" >/dev/null
    log_info "${file}: added ${key}=${value}."
  fi
}

system_upgrade() {
  section "System update & upgrade"
  log_info "Refreshing metadata and upgrading (this may take several minutes)…"
  sudo "$DNF_CMD" upgrade --refresh -y
  log_success "System upgrade complete."
}

enable_rpmfusion() {
  section "Repositories: RPM Fusion (Free + Non-Free)"
  local ver="$FEDORA_VERSION"
  local free_url="https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${ver}.noarch.rpm"
  local nonfree_url="https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${ver}.noarch.rpm"
  if rpm_is_installed rpmfusion-free-release; then
    log_info "RPM Fusion Free already installed."
  else
    log_info "Enabling RPM Fusion Free…"
    sudo "$DNF_CMD" install -y "$free_url"
  fi
  if rpm_is_installed rpmfusion-nonfree-release; then
    log_info "RPM Fusion Non-Free already installed."
  else
    log_info "Enabling RPM Fusion Non-Free…"
    sudo "$DNF_CMD" install -y "$nonfree_url"
  fi
  log_success "RPM Fusion repositories enabled."
}

enable_openh264() {
  section "Repositories: Cisco OpenH264"
  if sudo "$DNF_CMD" repolist 2>/dev/null | grep -qi "fedora-cisco-openh264"; then
    log_info "OpenH264 repo already known to ${DNF_CMD}."
  fi
  # dnf4 vs dnf5 config-manager syntax differs; try both idempotently.
  if sudo "$DNF_CMD" repolist enabled 2>/dev/null | grep -qi "fedora-cisco-openh264"; then
    log_info "OpenH264 repository already enabled."
  else
    log_info "Enabling OpenH264 repository…"
    if [[ "$DNF_CMD" == "dnf5" ]]; then
      sudo dnf5 config-manager setopt fedora-cisco-openh264.enabled=1 || true
    else
      sudo dnf config-manager --set-enabled fedora-cisco-openh264 || \
        sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1 || true
    fi
    # Fallback global switch used by the fedora-repos package.
    if sudo "$DNF_CMD" repolist enabled 2>/dev/null | grep -qi "fedora-cisco-openh264"; then
      log_success "OpenH264 repository enabled."
    else
      log_warn "Could not confirm OpenH264 is enabled; check 'dnf repolist'. Continuing."
    fi
  fi
}

enable_flathub() {
  section "Repositories: Flathub"
  if ! command_exists flatpak; then
    log_info "flatpak not present; installing…"
    ensure_dnf_packages flatpak
  fi
  if flatpak remote-list 2>/dev/null | grep -qi "^flathub"; then
    log_info "Flathub remote already configured."
  else
    log_info "Adding Flathub remote…"
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  fi
  if [[ -n "${FLATPAK_APPS:-}" ]]; then
    local app
    # shellcheck disable=SC2086 # intentional word-splitting of ID list
    for app in $FLATPAK_APPS; do
      if flatpak list --app 2>/dev/null | grep -qF "$app"; then
        log_info "Flatpak already installed: $app"
      else
        log_info "Installing flatpak: $app"
        flatpak install -y --noninteractive flathub "$app" \
          || log_warn "Flatpak install failed: $app"
      fi
    done
  else
    log_info "No FLATPAK_APPS requested; remote only (set FLATPAK_APPS=\"<id> …\" to install apps)."
  fi
  log_success "Flathub ready."
}

# ---------------------------------------------------------------------------
# 3. Core developer tooling & build essentials
# ---------------------------------------------------------------------------
install_build_essentials() {
  section "Build essentials"
  ensure_dnf_group "Development Tools"
  ensure_dnf_group "C Development"
  ensure_dnf_packages \
    cmake ninja-build clang lld gdb valgrind pkg-config \
    openssl-devel libffi-devel zlib-devel readline-devel sqlite-devel
  log_success "Build essentials installed."
}

install_cli_toolkit() {
  section "Modern CLI & utility toolkit"
  # NOTE: 'eza' replaced 'exa' in Fedora repos; 'fd-find' provides the 'fd' binary.
  ensure_dnf_packages \
    git gh ripgrep fd-find fzf bat eza jq htop btop tmux zsh stow direnv \
    unzip curl wget
  log_success "CLI toolkit installed."
}

install_editors_terminals() {
  section "Terminal & editors"
  ensure_dnf_packages neovim kitty
  log_success "neovim + kitty installed."
}

configure_kitty() {
  section "Kitty terminal (Catppuccin Mocha, JetBrainsMono Nerd 13)"
  command_exists kitty || ensure_dnf_packages kitty

  # --- JetBrainsMono Nerd Font, user-space (kitty + editor/prompt glyphs) ---
  local font_dir="$HOME/.local/share/fonts"
  mkdir -p "$font_dir"
  if fc-list 2>/dev/null | grep -qi "JetBrainsMono.*Nerd"; then
    log_info "JetBrainsMono Nerd Font already installed."
  else
    log_info "Installing JetBrainsMono Nerd Font into ${font_dir}…"
    local base="https://github.com/ryanoasis/nerd-fonts/raw/${NERD_FONTS_REF}/patched-fonts/JetBrainsMono"
    local spec dest ok=1
    for spec in "Regular:Regular" "Bold:Bold" "Italic:Italic" "BoldItalic:BoldItalic"; do
      local style="${spec%%:*}" dir="${spec##*:}"
      dest="$font_dir/JetBrainsMonoNerdFont-${style}.ttf"
      fetch_file "$base/$dir/JetBrainsMonoNerdFont-${style}.ttf" "$dest" \
        || { log_warn "Font download failed: ${style}"; ok=0; }
    done
    fc-cache -f "$font_dir" &>/dev/null || true
    if fc-list 2>/dev/null | grep -qi "JetBrainsMono.*Nerd"; then
      log_success "JetBrainsMono Nerd Font installed."
    elif [[ "$ok" == "1" ]]; then
      log_success "JetBrainsMono Nerd Font downloaded (fontconfig will pick it up on next login)."
    else
      log_warn "JetBrainsMono Nerd Font incomplete; kitty falls back to monospace. Re-run to retry."
    fi
  fi

  # --- Drop-in config (re-runs overwrite this file only; kitty.conf preserved) ---
  local kitty_dir="$HOME/.config/kitty"
  local dropin="$kitty_dir/fedora-dev.conf"
  mkdir -p "$kitty_dir"
  cat >"$dropin" <<'KITTY_EOF'
# Managed by setup-fedora-dev.sh (idempotent; safe to tweak, re-runs overwrite this file only).
# Theme: Catppuccin Mocha | Font: JetBrainsMono Nerd Font 13.

font_family      JetBrainsMono Nerd Font
bold_font        auto
italic_font      auto
bold_italic_font auto
font_size        13.0

shell zsh

foreground           #cdd6f4
background           #1e1e2e
selection_foreground #cdd6f4
selection_background #45475a
cursor               #f5e0dc
cursor_text_color    #1e1e2e
url_color            #89dceb

active_tab_foreground   #11111b
active_tab_background   #cba6f7
inactive_tab_foreground #cdd6f4
inactive_tab_background #181825
tab_bar_background      #11111b
tab_bar_style           powerline
tab_powerline_style     slanted

color0  #45475a
color8  #585b70
color1  #f38ba8
color9  #f38ba8
color2  #a6e3a1
color10 #a6e3a1
color3  #f9e2af
color11 #f9e2af
color4  #89b4fa
color12 #89b4fa
color5  #f5c2e7
color13 #f5c2e7
color6  #94e2d5
color14 #94e2d5
color7  #bac2de
color15 #a6adc8

scrollback_lines      10000
window_padding_width  8
enable_audio_bell     no
confirm_os_window_close 0
KITTY_EOF
  log_info "Kitty drop-in written: ${dropin}"

  # Wire the drop-in at the TOP of kitty.conf so user lines below still win.
  backup_file "$kitty_dir/kitty.conf"
  touch "$kitty_dir/kitty.conf"
  if grep -qE '^[[:space:]]*include[[:space:]]+fedora-dev\.conf' "$kitty_dir/kitty.conf"; then
    log_info "kitty.conf already includes fedora-dev.conf."
  else
    local tmp_k
    tmp_k="$(mktemp)"
    printf 'include fedora-dev.conf\n' >"$tmp_k"
    cat "$kitty_dir/kitty.conf" >>"$tmp_k"
    cat "$tmp_k" >"$kitty_dir/kitty.conf"
    rm -f "$tmp_k"
    log_info "kitty.conf now includes fedora-dev.conf (first line)."
  fi

  # --- GNOME default terminal → kitty ---
  if command_exists gsettings; then
    if gsettings set org.gnome.desktop.default-applications.terminal exec 'kitty' 2>/dev/null; then
      log_success "kitty set as GNOME default terminal."
    else
      log_warn "Could not set GNOME default terminal (schema missing?). Set it manually in Settings."
    fi
  else
    log_info "gsettings not found; skipping default-terminal switch."
  fi
  log_success "Kitty setup complete."
}

# Idempotent git clone-or-update helper for user-space repos.
git_clone_or_update() {
  local url="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    log_info "Updating $(basename "$dest")…"
    git -C "$dest" pull --ff-only 2>/dev/null || log_warn "Update failed for ${dest}; continuing with existing checkout."
  elif [[ -d "$dest" ]]; then
    log_warn "${dest} exists but is not a git repo; leaving untouched."
  else
    log_info "Cloning $(basename "$dest")…"
    git clone --depth=1 "$url" "$dest"
  fi
}

install_zsh_p10k() {
  section "Zsh + Oh My Zsh + Powerlevel10k"
  command_exists zsh || ensure_dnf_packages zsh
  ensure_dnf_packages git curl fontconfig

  # --- Meslo Nerd Font (Powerlevel10k's recommended font), user-space ---
  local font_dir="$HOME/.local/share/fonts"
  mkdir -p "$font_dir"
  if fc-list 2>/dev/null | grep -qi "MesloLGS"; then
    log_info "Meslo Nerd Font already installed."
  else
    log_info "Installing Meslo Nerd Font into ${font_dir}…"
    local base="https://github.com/romkatv/powerlevel10k-media/raw/master"
    local f
    for f in "MesloLGS%20NF%20Regular.ttf" "MesloLGS%20NF%20Bold.ttf" \
             "MesloLGS%20NF%20Italic.ttf" "MesloLGS%20NF%20Bold%20Italic.ttf"; do
      local out="$font_dir/$(printf '%s' "$f" | sed 's/%20/ /g')"
      fetch_file "$base/$f" "$out" || log_warn "Font download failed: $f"
    done
    fc-cache -f "$font_dir" &>/dev/null || true
    fc-list 2>/dev/null | grep -qi "MesloLGS" \
      && log_success "Meslo Nerd Font installed (select 'MesloLGS NF' in kitty/terminal font settings)." \
      || log_warn "Meslo font not detected by fontconfig; set your terminal font to 'MesloLGS NF' manually."
  fi

  # --- Oh My Zsh (unattended, keep existing .zshrc) ---
  local omz_dir="$HOME/.oh-my-zsh"
  if [[ -d "$omz_dir" ]]; then
    log_info "Oh My Zsh already installed; updating…"
    git -C "$omz_dir" pull --ff-only 2>/dev/null || log_warn "Oh My Zsh update failed; continuing."
  else
    log_info "Installing Oh My Zsh (unattended, keep-zshrc)…"
    local omz_installer
    omz_installer="$(mktemp)"
    # Never `sh -c "$(curl …)"`: an empty download would "succeed" silently.
    if fetch_file "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" "$omz_installer"; then
      sh "$omz_installer" "" --unattended --keep-zshrc \
        || log_warn "Oh My Zsh installer failed; continuing without OMZ (re-run to retry)."
      rm -f "$omz_installer"
    else
      rm -f "$omz_installer"
      log_warn "Could not download the Oh My Zsh installer; continuing without OMZ (re-run to retry)."
    fi
  fi
  local zsh_custom="${ZSH_CUSTOM:-$omz_dir/custom}"
  mkdir -p "$zsh_custom/themes" "$zsh_custom/plugins"

  # --- Plugins: all necessary for dev (external + OMZ builtins) ---
  git_clone_or_update "https://github.com/zsh-users/zsh-autosuggestions.git" "$zsh_custom/plugins/zsh-autosuggestions"
  git_clone_or_update "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$zsh_custom/plugins/zsh-syntax-highlighting"
  git_clone_or_update "https://github.com/zsh-users/zsh-completions.git" "$zsh_custom/plugins/zsh-completions"

  # --- Powerlevel10k theme ---
  git_clone_or_update "https://github.com/romkatv/powerlevel10k.git" "$zsh_custom/themes/powerlevel10k"

  # --- ~/.zshrc: create from OMZ template if missing, then enforce theme/plugins ---
  backup_file "$HOME/.zshrc"
  touch "$HOME/.zshrc"
  if ! grep -q "oh-my-zsh" "$HOME/.zshrc" 2>/dev/null; then
    if [[ -f "$omz_dir/templates/zshrc.zsh-template" ]]; then
      log_info "Seeding ~/.zshrc from Oh My Zsh template…"
      cp "$omz_dir/templates/zshrc.zsh-template" "$HOME/.zshrc"
    fi
  fi
  if grep -qE '^ZSH_THEME=' "$HOME/.zshrc"; then
    sed -i -E 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$HOME/.zshrc"
  else
    printf '%s\n' 'ZSH_THEME="powerlevel10k/powerlevel10k"' >>"$HOME/.zshrc"
  fi
  local dev_plugins='plugins=(git gh docker python pip node npm rust cargo golang sudo command-not-found colored-man-pages direnv zsh-autosuggestions zsh-syntax-highlighting zsh-completions)'
  if grep -qE '^plugins=\(' "$HOME/.zshrc"; then
    sed -i -E "s|^plugins=\(.*|${dev_plugins}|" "$HOME/.zshrc"
  else
    printf '%s\n' "$dev_plugins" >>"$HOME/.zshrc"
  fi
  # p10k instant-prompt preamble belongs at the very top of .zshrc.
  if ! grep -q "p10k-instant-prompt" "$HOME/.zshrc"; then
    local tmp_zsh
    tmp_zsh="$(mktemp)"
    cat >"$tmp_zsh" <<'PREAMBLE_EOF'
# Enable Powerlevel10k instant prompt (keep near the top of ~/.zshrc).
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
PREAMBLE_EOF
    cat "$HOME/.zshrc" >>"$tmp_zsh"
    cat "$tmp_zsh" >"$HOME/.zshrc"
    rm -f "$tmp_zsh"
  fi
  # Load existing (or future, post-wizard) p10k config.
  ensure_line_in_file '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' "$HOME/.zshrc"
  log_success "Oh My Zsh + Powerlevel10k wired in ~/.zshrc."

  # --- Default shell → zsh ---
  if [[ "${SHELL:-}" == *"zsh"* ]] || [[ "$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || echo "")" == *"zsh" ]]; then
    log_info "Default login shell is already zsh."
  elif [[ "$NONINTERACTIVE" == "1" ]]; then
    # chsh does its own PAM auth and may block without a TTY — never attempt it blind.
    log_info "Skipping 'chsh' in non-interactive mode. Run manually: chsh -s \$(command -v zsh)"
  else
    log_info "Setting zsh as the default login shell…"
    if chsh -s "$(command -v zsh)" "$USER"; then
      log_warn "Default shell changed to zsh — log out and back in for it to take effect."
    else
      log_warn "chsh failed; run manually: chsh -s \$(command -v zsh)"
    fi
  fi

  # --- Interactive `p10k configure` wizard (never overwrites existing config) ---
  if [[ -f "$HOME/.p10k.zsh" ]]; then
    log_info "~/.p10k.zsh already exists; skipping wizard (run 'p10k configure' to re-run it)."
  elif [[ "$NONINTERACTIVE" != "1" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
    log_info "Launching interactive 'p10k configure' wizard…"
    zsh -i -c 'p10k configure' || log_warn "'p10k configure' exited; re-run it later with: p10k configure"
  else
    log_info "Skipping interactive 'p10k configure' (non-interactive or no TTY). After restarting your shell, run: p10k configure"
  fi
  log_success "Zsh setup complete."
}

# ---------------------------------------------------------------------------
# 4. Polyglot runtimes & version managers (user-space)
# ---------------------------------------------------------------------------
install_fnm_node() {
  section "Node.js via fnm (user-space)"
  local fnm_bin="$HOME/.local/bin/fnm"
  mkdir -p "$HOME/.local/bin"
  if command_exists fnm || [[ -x "$fnm_bin" ]]; then
    log_info "fnm already installed ($(fnm --version 2>/dev/null || echo present))."
  else
    log_info "Installing fnm (Fast Node Manager) into ~/.local/bin…"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$HOME/.local/bin" --skip-shell
  fi
  export PATH="$HOME/.local/bin:$PATH"
  if ! command_exists fnm; then
    log_error "fnm installation failed (binary not on PATH). Aborting Node setup."
    return 1
  fi
  # LTS install is idempotent: fnm skips already-installed versions.
  log_info "Installing Node.js LTS (fnm install --lts)…"
  fnm install --lts
  # Pin LTS as default so new shells get it automatically.
  if fnm default lts-latest 2>/dev/null; then
    log_success "Node.js LTS set as default (lts-latest)."
  else
    # Fallback for older fnm releases: parse the newest installed version.
    local lts_ver
    lts_ver="$(fnm ls 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1 || true)"
    if [[ -n "${lts_ver:-}" ]]; then
      fnm default "$lts_ver" 2>/dev/null || fnm alias default "$lts_ver" 2>/dev/null || true
      log_success "Node.js LTS default set to ${lts_ver}."
    else
      log_warn "Could not pin a default Node version; run 'fnm default lts-latest' manually."
    fi
  fi
  # pnpm + yarn via corepack (ships with Node ≥ 16.9). Idempotent.
  export PATH="$HOME/.local/share/fnm:$PATH"
  # shellcheck disable=SC1090
  eval "$(fnm env --shell bash 2>/dev/null)" || true
  if command_exists corepack; then
    corepack enable 2>/dev/null || true
    # Newer corepack: 'prepare --activate' is the supported path.
    corepack prepare pnpm@latest --activate 2>/dev/null || npm install -g pnpm 2>/dev/null || true
    corepack prepare yarn@stable --activate 2>/dev/null || npm install -g yarn 2>/dev/null || true
  else
    npm install -g pnpm yarn 2>/dev/null || log_warn "Could not install pnpm/yarn globally; run 'corepack enable' manually."
  fi
  log_success "Node.js toolchain ready (node $(node --version 2>/dev/null || echo '?'))."
}

install_uv_pyenv() {
  section "Python via uv + pyenv (user-space)"
  if command_exists uv; then
    log_info "uv already installed ($(uv --version 2>/dev/null))."
  else
    log_info "Installing uv (Astral) into ~/.local/bin…"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  fi
  local pyenv_root="$HOME/.pyenv"
  if [[ -d "$pyenv_root/.git" ]]; then
    log_info "pyenv already cloned; updating…"
    git -C "$pyenv_root" pull --ff-only 2>/dev/null || log_warn "pyenv update failed; continuing with existing checkout."
  elif [[ -d "$pyenv_root" ]]; then
    log_info "pyenv directory already exists at ${pyenv_root}."
  else
    log_info "Cloning pyenv into ~/.pyenv…"
    git clone https://github.com/pyenv/pyenv.git "$pyenv_root"
  fi
  # pyenv-virtualenv plugin (idempotent).
  if [[ -d "$pyenv_root/plugins/pyenv-virtualenv/.git" ]]; then
    git -C "$pyenv_root/plugins/pyenv-virtualenv" pull --ff-only 2>/dev/null || true
  elif [[ ! -d "$pyenv_root/plugins/pyenv-virtualenv" ]]; then
    git clone https://github.com/pyenv/pyenv-virtualenv.git "$pyenv_root/plugins/pyenv-virtualenv" || true
  fi
  log_success "uv + pyenv ready."
}

install_rustup() {
  section "Rust via rustup (user-space)"
  export PATH="$HOME/.cargo/bin:$PATH"
  if command_exists rustup; then
    log_info "rustup already installed; updating toolchain…"
    rustup update stable 2>/dev/null || rustup update 2>/dev/null || true
  else
    log_info "Installing rustup (default stable toolchain)…"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile default
    # shellcheck disable=SC1090
    [[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env" || true
  fi
  log_info "Ensuring Rust components: rust-analyzer, clippy, rustfmt…"
  rustup component add rust-analyzer clippy rustfmt 2>/dev/null || true
  log_success "Rust ready ($(rustc --version 2>/dev/null || echo 'rustc unavailable until shell reload'))."
}

install_go() {
  section "Go toolchain"
  if command_exists go; then
    log_info "Go already installed ($(go version 2>/dev/null))."
  else
    log_info "Installing Go via Fedora package…"
    ensure_dnf_packages golang
  fi
  export GOPATH="${GOPATH:-$HOME/go}"
  export GOBIN="${GOBIN:-$HOME/go/bin}"
  mkdir -p "$GOBIN"
  log_success "Go ready ($(go version 2>/dev/null || echo 'go unavailable until shell reload')). GOPATH=${GOPATH} GOBIN=${GOBIN}."
}

install_java() {
  section "Java/JVM"
  if rpm_is_installed java-21-openjdk-devel; then
    log_info "java-21-openjdk-devel already installed."
  else
    log_info "Installing OpenJDK 21…"
    ensure_dnf_packages java-21-openjdk-devel
  fi
  if [[ "$INSTALL_SDKMAN" == "1" ]]; then
    install_sdkman
  else
    log_info "SDKMAN! skipped (pass --sdkman or INSTALL_SDKMAN=1 to install)."
  fi
  log_success "Java ready ($(java -version 2>&1 | head -n1 || echo 'java unavailable until shell reload'))."
}

install_sdkman() {
  local sdk_dir="$HOME/.sdkman"
  if [[ -s "$sdk_dir/bin/sdkman-init.sh" ]]; then
    log_info "SDKMAN! already installed at ${sdk_dir}."
    return 0
  fi
  log_info "Installing SDKMAN! (user-space)…"
  curl -s "https://get.sdkman.io" | bash
  log_success "SDKMAN! installed (restart shell, then 'sdk list java')."
}

# ---------------------------------------------------------------------------
# 5. Containers, virtualization & networking
# ---------------------------------------------------------------------------
install_containers() {
  section "Container stack (Podman)"
  ensure_dnf_packages podman podman-docker podman-compose buildah skopeo
  # podman-docker provides /usr/bin/docker shim; verify the compat path.
  log_success "Podman stack installed."
  if [[ "$INSTALL_DOCKER" == "1" ]]; then
    install_docker_ce
  else
    log_info "Docker CE skipped (pass --docker or INSTALL_DOCKER=1 to install)."
  fi
}

install_docker_ce() {
  section "Docker CE (optional)"
  if command_exists docker && rpm_is_installed docker-ce; then
    log_info "Docker CE already installed."
  else
    log_info "Installing Docker CE repository + engine…"
    sudo "$DNF_CMD" config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
      || sudo "$DNF_CMD" config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
    ensure_dnf_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  sudo systemctl enable --now docker containerd 2>/dev/null || sudo systemctl enable --now docker || true
  if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    log_info "User '$USER' already in 'docker' group."
  else
    sudo usermod -aG docker "$USER"
    log_warn "User '$USER' added to 'docker' group — log out and back in for it to take effect."
  fi
  log_success "Docker CE ready."
}

install_virtualization() {
  section "Virtualization (KVM/QEMU/libvirt)"
  ensure_dnf_packages qemu-kvm libvirt virt-manager virt-install
  log_info "Enabling libvirtd…"
  sudo systemctl enable --now libvirtd
  if id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
    log_info "User '$USER' already in 'libvirt' group."
  else
    sudo usermod -aG libvirt "$USER"
    log_warn "User '$USER' added to 'libvirt' group — log out and back in for it to take effect."
  fi
  log_success "Virtualization stack ready."
}

# ---------------------------------------------------------------------------
# 6. Shell & PATH configurations (idempotent managed block)
# ---------------------------------------------------------------------------
build_shell_block() {
  cat <<'BLOCK_EOF'
# --- Managed by setup-fedora-dev.sh (idempotent; do not edit markers) ---
# PATH additions (kept first so user-space tools shadow system ones)
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/go/bin:$PATH"
export PATH="$HOME/.cargo/bin:$PATH"

# Go workspace
export GOPATH="${GOPATH:-$HOME/go}"
export GOBIN="${GOBIN:-$HOME/go/bin}"

# pyenv (only if cloned)
if [ -d "$HOME/.pyenv" ]; then
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  if command -v pyenv >/dev/null 2>&1; then
    eval "$(pyenv init -)" || true
    [ -d "$PYENV_ROOT/plugins/pyenv-virtualenv" ] && eval "$(pyenv virtualenv-init -)" 2>/dev/null || true
  fi
fi

# fnm (Fast Node Manager)
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd)" || true
fi

# rustup cargo env
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true

# SDKMAN! (only if installed)
[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh"

# direnv hook (only if installed)
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook "${SHELL##*/}")" || true

# Completions: interactive shells only (keeps script/scp fast),
# and FEDORA_DEV_NO_COMPLETIONS=1 disables them entirely.
if [[ $- == *i* && -z "${FEDORA_DEV_NO_COMPLETIONS:-}" ]]; then
  command -v gh >/dev/null 2>&1 && eval "$(gh completion -s "${SHELL##*/}" 2>/dev/null)" || true
  command -v rustup >/dev/null 2>&1 && eval "$(rustup completions "${SHELL##*/}" 2>/dev/null)" || true
  command -v uv >/dev/null 2>&1 && eval "$(uv generate-shell-completion "${SHELL##*/}" 2>/dev/null)" || true
  command -v fnm >/dev/null 2>&1 && eval "$(fnm completions --shell "${SHELL##*/}" 2>/dev/null)" || true
fi
BLOCK_EOF
}

configure_shells() {
  section "Shell & PATH configuration (~/.bashrc, ~/.zshrc)"
  local block
  block="$(build_shell_block)"
  backup_file "$HOME/.bashrc"
  backup_file "$HOME/.zshrc"
  ensure_managed_block "$HOME/.bashrc" "$block"
  log_info "~/.bashrc wired (managed block upserted)."
  # zsh is a hard requirement now (OMZ + p10k installer above guarantees it).
  ensure_managed_block "$HOME/.zshrc" "$block"
  log_info "~/.zshrc wired (managed block upserted; OMZ/p10k lines preserved)."
  log_success "Shell configuration complete (re-run safe: block is replaced, never duplicated)."
}

# ---------------------------------------------------------------------------
# 7. Verification & post-install report
# ---------------------------------------------------------------------------
verify_tool() {
  # verify_tool <binary> <version-args...> — prints "name version" or MISSING.
  local bin="$1"; shift
  if ! command -v "$bin" &>/dev/null; then
    printf '%-14s %s\n' "$bin" "MISSING"
    return 1
  fi
  local ver
  # Special cases first.
  case "$bin" in
    python3) ver="$(python3 --version 2>&1)" ;;
    go)      ver="$(go version 2>&1)" ;;
    java)    ver="$(java -version 2>&1 | head -n1)" ;;
    *)       ver="$("$bin" "$@" 2>&1 | head -n1)" ;;
  esac
  printf '%-14s %s\n' "$bin" "$ver"
  return 0
}

run_verification() {
  section "Verification"
  # Make freshly-installed user-space tools visible in this shell.
  export PATH="$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:$HOME/.pyenv/bin:$PATH"
  # shellcheck disable=SC1090
  [[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env" || true
  export GOPATH="${GOPATH:-$HOME/go}" GOBIN="${GOBIN:-$HOME/go/bin}"

  local failures=0
  local report
  report="$(mktemp)"
  {
    verify_tool git --version        || failures=$((failures+1))
    verify_tool gcc --version        || failures=$((failures+1))
    verify_tool clang --version      || failures=$((failures+1))
    verify_tool rustc --version      || failures=$((failures+1))
    verify_tool node --version       || failures=$((failures+1))
    verify_tool python3 --version    || failures=$((failures+1))
    verify_tool uv --version         || failures=$((failures+1))
    verify_tool podman --version     || failures=$((failures+1))
    echo "--- extra ---"
    verify_tool nvim --version       || true
    verify_tool kitty --version      || true
    verify_tool fnm --version        || true
    verify_tool pyenv --version      || true
    verify_tool go version           || true
    verify_tool java -version        || true
    verify_tool gh --version         || true
    verify_tool fzf --version        || true
    verify_tool rg --version         || true
    verify_tool bat --version        || true
    verify_tool eza --version        || true
    verify_tool tmux -V              || true
    verify_tool zsh --version        || true
    verify_tool direnv version       || true
  } | tee "$report"

  echo ""
  if [[ "$failures" -eq 0 ]]; then
    log_success "All 8 core binaries functional (git, gcc, clang, rustc, node, python3, uv, podman)."
  else
    log_warn "${failures} core tool(s) MISSING — see table above. Re-run the script, then check Post-install notes."
  fi
  # Informational (non-failing) Zsh/OMZ/p10k checks.
  local _zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  [[ -d "$HOME/.oh-my-zsh" ]] \
    && log_success "Oh My Zsh present (~/.oh-my-zsh)." \
    || log_warn "Oh My Zsh MISSING (~/.oh-my-zsh)."
  [[ -d "$_zsh_custom/themes/powerlevel10k" ]] \
    && log_success "Powerlevel10k theme present." \
    || log_warn "Powerlevel10k theme MISSING."
  for _plug in zsh-autosuggestions zsh-syntax-highlighting zsh-completions; do
    [[ -d "$_zsh_custom/plugins/$_plug" ]] \
      && log_info "zsh plugin present: $_plug" \
      || log_warn "zsh plugin MISSING: $_plug"
  done
  [[ -f "$HOME/.p10k.zsh" ]] \
    && log_info "~/.p10k.zsh configured." \
    || log_info "~/.p10k.zsh not yet created — run 'p10k configure'."
  # Informational (non-failing) kitty checks.
  [[ -f "$HOME/.config/kitty/fedora-dev.conf" ]] \
    && log_success "Kitty drop-in present (Catppuccin Mocha, JetBrainsMono NF 13)." \
    || log_warn "Kitty drop-in MISSING (~/.config/kitty/fedora-dev.conf)."
  fc-list 2>/dev/null | grep -qi "JetBrainsMono.*Nerd" \
    && log_info "JetBrainsMono Nerd Font detected." \
    || log_info "JetBrainsMono Nerd Font not detected — check ~/.local/share/fonts."
  VERIFY_REPORT_FILE="$report"
}

print_summary() {
  section "Post-install summary"
  cat <<'EOF'
  ┌────────────────────┬──────────────────────────────────────────────┐
  │ Area               │ What was installed / configured              │
  ├────────────────────┼──────────────────────────────────────────────┤
  │ System             │ DNF tuned, full upgrade, RPM Fusion,         │
  │                    │ OpenH264, Flathub                            │
  │ Build              │ @development-tools, @c-development, cmake,   │
  │                    │ ninja, clang, lld, gdb, valgrind, *-devel    │
  │ CLI toolkit        │ git, gh, rg, fd, fzf, bat, eza, jq, htop,    │
  │                    │ btop, tmux, zsh, stow, direnv, nvim, kitty   │
  │ Node               │ fnm (user-space) + Node LTS + pnpm + yarn    │
  │ Python             │ uv + pyenv + pyenv-virtualenv (user-space)   │
  │ Rust               │ rustup stable + rust-analyzer/clippy/fmt     │
  │ Go                 │ golang + ~/go (GOPATH/GOBIN wired)           │
  │ Java               │ java-21-openjdk-devel (+ SDKMAN! if asked)   │
  │ Containers         │ podman stack (+ Docker CE if --docker)       │
  │ Virtualization     │ qemu-kvm, libvirt, virt-manager, libvirtd    │
  │ Zsh                │ Oh My Zsh + Powerlevel10k, dev plugins,      │
  │                    │ Meslo Nerd Font, zsh default shell           │
  │ Kitty              │ Catppuccin Mocha, JetBrainsMono Nerd 13,     │
  │                    │ drop-in conf, GNOME default terminal         │
  │ Shell              │ Managed PATH block in ~/.bashrc + ~/.zshrc   │
  └────────────────────┴──────────────────────────────────────────────┘
EOF
  echo ""
  log_info "NEXT STEPS (important):"
  echo "  1. Log out and back in for 'docker' / 'libvirt' group membership AND the new"
  echo "     zsh default shell to take effect. (Verify later with: id -nG; echo \$SHELL)"
  echo "  2. Restart your shell or run:  source ~/.zshrc   # zsh is now the default"
  echo "  3. If the 'p10k configure' wizard did not run, launch it manually:"
  echo "       p10k configure"
  echo "     (Requires a Nerd Font — JetBrainsMono NF is installed; select it"
  echo "      in kitty if glyphs look off: kitty font is preconfigured to size 13.)"
  echo "  4. Confirm runtimes:"
  echo "       node --version && pnpm --version && yarn --version"
  echo "       uv --version && pyenv --versions"
  echo "       rustc --version && cargo --version"
  echo "       go version && echo \$GOPATH"
  echo "       java -version"
  echo "  5. This script is idempotent — re-run anytime with:"
  echo "       ./$SCRIPT_NAME"
  echo "     Your ~/.p10k.zsh is never overwritten on re-runs."
  echo "     Add Docker/SDKMAN later with: ./$SCRIPT_NAME --docker --sdkman"
  echo "     Original dotfiles are kept as *.pre-fedora-dev.bak (first run only)."
  echo "  6. Full log (appended every run) saved to: $LOG_FILE"
  if [[ -n "${VERIFY_REPORT_FILE:-}" ]]; then
    echo "     Verification snapshot: $VERIFY_REPORT_FILE"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log_run_header() {
  # Append (never truncate): keep history across re-runs.
  {
    printf '\n================================================================\n'
    printf 'Run started: %s | args: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    printf 'Flags: docker=%s sdkman=%s skip_upgrade=%s only=%s dry_run=%s dnf=%s\n' \
      "$INSTALL_DOCKER" "$INSTALL_SDKMAN" "$SKIP_UPGRADE" "${ONLY:-all}" "$DRY_RUN" "$DNF_CMD"
  } >>"$LOG_FILE" 2>/dev/null || true
}

dry_run_plan() {
  log_info "DRY RUN — no changes will be made (sudo prompt and snapshot skipped)."
  preflight_os_check
  preflight_network_check
  preflight_disk_check
  section "Dry-run plan"
  local entry token desc
  for entry in "${_STEPS[@]}"; do
    token="${entry%%:*}"
    desc="${entry#*:}"
    if should_run "$token"; then
      if [[ "$token" == "upgrade" && "$SKIP_UPGRADE" == "1" ]]; then
        log_info "[skip] ${desc} (--skip-upgrade)"
      else
        log_info "[run]  ${desc}"
      fi
    else
      log_info "[skip] ${desc} (--only filter)"
    fi
  done
  log_info "Options: docker=${INSTALL_DOCKER} sdkman=${INSTALL_SDKMAN} flatpak_apps='${FLATPAK_APPS:-none}'"
  log_info "Pre-flight, verification and summary always run in a real execution."
}

main() {
  parse_args "$@"
  if [[ "$VERBOSE" == "1" ]]; then
    set -x
  fi
  validate_only
  log_run_header "$@"
  log_info "Starting ${SCRIPT_NAME} (docker=${INSTALL_DOCKER}, sdkman=${INSTALL_SDKMAN}, dnf=${DNF_CMD}). Log: ${LOG_FILE}"

  if [[ "$DRY_RUN" == "1" ]]; then
    dry_run_plan
    exit 0
  fi

  run_preflight

  if ! confirm "Proceed with setup (system upgrade + dev environment)?"; then
    log_info "Aborted by user."
    exit 0
  fi

  if should_run tune; then tune_dnf; fi
  if should_run upgrade; then
    if [[ "$SKIP_UPGRADE" == "1" ]]; then
      log_info "Skipping system upgrade (--skip-upgrade)."
    else
      system_upgrade
    fi
  fi
  if should_run repos; then
    enable_rpmfusion
    enable_openh264
    enable_flathub
  fi

  if should_run build; then install_build_essentials; fi
  if should_run cli; then install_cli_toolkit; fi
  if should_run editors; then install_editors_terminals; fi
  if should_run kitty; then configure_kitty; fi
  if should_run zsh; then install_zsh_p10k; fi

  if should_run node; then install_fnm_node; fi
  if should_run python; then install_uv_pyenv; fi
  if should_run rust; then install_rustup; fi
  if should_run go; then install_go; fi
  if should_run java; then install_java; fi

  if should_run containers; then install_containers; fi
  if should_run virt; then install_virtualization; fi

  if should_run shells; then configure_shells; fi
  run_verification
  print_summary

  log_success "Setup complete. Restart your shell (or log out/in) to pick up all changes."
}

main "$@"
