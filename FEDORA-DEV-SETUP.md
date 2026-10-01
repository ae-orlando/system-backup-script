# Fedora Dev Setup — Usage Guide

`setup-fedora-dev.sh` turns a fresh Fedora Workstation install into a polyglot dev environment (system tuning, build tools, Node/Python/Rust/Go/Java, podman, KVM, zsh + Oh My Zsh + Powerlevel10k, kitty). Fully automated and idempotent — safe to re-run anytime.

## Quickstart (fresh machine)

```bash
chmod +x setup-fedora-dev.sh
./setup-fedora-dev.sh --dry-run   # optional: preview the plan, changes nothing
./setup-fedora-dev.sh
```

Then log out and back in (groups + default shell), open kitty, and run `p10k configure` if the wizard didn't run during setup. Full checklist in [Post-install](#post-install-checklist).

## Prerequisites

- Fedora Workstation (other Fedora editions warn but continue; non-Fedora exits 1).
- Regular user with `sudo` rights. Do **not** run as root (exits 2).
- Internet access, ≥ 20 GB free disk (`MIN_DISK_GB` overrides).
- Optional: `snapper` or `timeshift` for an automatic pre-change snapshot.

## Flag reference

Every flag has an env-var equivalent. CLI flags win by assignment order (last one set applies).

| CLI flag | Env var | Default | Effect |
|---|---|---|---|
| `-y, --yes` | `NONINTERACTIVE=1` | off | No prompts (still asks sudo password once). Skips `p10k configure` wizard and `chsh`; both printed as follow-ups |
| `--docker` / `--no-docker` | `INSTALL_DOCKER=1` | off | Install Docker CE, enable services, add user to `docker` group |
| `--sdkman` / `--no-sdkman` | `INSTALL_SDKMAN=1` | off | Install SDKMAN! to `~/.sdkman` |
| `--skip-upgrade` | `SKIP_UPGRADE=1` | off | Skip the full `dnf upgrade --refresh` (fast re-runs) |
| `--only a,b` | `ONLY=a,b` | all | Run only these sections (see tokens below). Pre-flight, verification, summary always run |
| `--dry-run` | `DRY_RUN=1` | off | Read-only pre-flight + printed plan. Changes nothing |
| `-v, --verbose` | `VERBOSE=1` | off | Trace execution (`set -x`) for debugging |
| `-h, --help` | — | — | Print help and exit |
| — | `FLATPAK_APPS="id1 id2"` | none | Flatpak app IDs to install from Flathub after adding the remote |
| — | `NERD_FONTS_REF=<ref>` | `master` | Git ref for JetBrainsMono Nerd Font downloads |
| — | `MIN_DISK_GB=<n>` | `20` | Free-disk requirement on `/` |
| — | `LOG_FILE=<path>` | `~/fedora-dev-setup.log` | Log location (appended every run) |

## `--only` section tokens

| Token | Runs |
|---|---|
| `tune` | DNF tuning (`max_parallel_downloads=10`, `fastestmirror=True`) |
| `upgrade` | Full `dnf upgrade --refresh` (honors `--skip-upgrade`) |
| `repos` | RPM Fusion Free/Non-Free, Cisco OpenH264, Flathub (+ `FLATPAK_APPS`) |
| `build` | `@development-tools`, `@c-development`, cmake/ninja/clang/lld/gdb/valgrind, `*-devel` libs |
| `cli` | git, gh, ripgrep, fd, fzf, bat, eza, jq, htop, btop, tmux, zsh, stow, direnv, unzip, curl, wget |
| `editors` | neovim, kitty packages |
| `kitty` | JetBrainsMono Nerd Font, Catppuccin Mocha drop-in (`~/.config/kitty/fedora-dev.conf`), GNOME default terminal |
| `zsh` | Meslo font, Oh My Zsh, dev plugins, Powerlevel10k, `chsh` to zsh, `p10k configure` wizard |
| `node` | fnm (user-space) + Node LTS (default) + pnpm + yarn |
| `python` | uv + pyenv + pyenv-virtualenv (user-space) |
| `rust` | rustup stable + rust-analyzer, clippy, rustfmt |
| `go` | golang package, `~/go` (`GOPATH`/`GOBIN` wired) |
| `java` | `java-21-openjdk-devel` (+ SDKMAN! with `--sdkman`) |
| `containers` | podman, podman-docker, podman-compose, buildah, skopeo (+ Docker CE with `--docker`) |
| `virt` | qemu-kvm, libvirt, virt-manager, `libvirtd` enabled, user in `libvirt` group |
| `shells` | Managed PATH block in `~/.bashrc` + `~/.zshrc` (replaced, never duplicated) |

## Run it

```bash
./setup-fedora-dev.sh
```

1. Enter your `sudo` password once (kept alive in the background, released on exit).
2. Confirm `Proceed with setup?` (Enter = yes; skipped with `-y`).
3. Wait (~15–30 min first run, mostly the system upgrade), ending with a verification table and summary.
4. `p10k configure` launches interactively when possible. Existing `~/.p10k.zsh` is never overwritten.

## Post-install checklist

```bash
# 1. Log out and back in (activates docker/libvirt groups AND the zsh default shell)
id -nG            # expect docker and/or libvirt (if installed)
echo $SHELL       # expect .../zsh

# 2. Open kitty (now the default terminal: Catppuccin Mocha, JetBrainsMono NF 13).
#    If glyphs look off, select "JetBrainsMono Nerd Font" in your terminal font settings.
p10k configure    # only if the wizard didn't run during setup

# 3. Fresh shell, then confirm runtimes
source ~/.zshrc
node --version && pnpm --version && yarn --version
uv --version && pyenv --versions
rustc --version && cargo --version
go version && echo $GOPATH
java -version
podman --version
```

Shell completions (gh, rustup, uv, fnm) load in interactive shells only; set `FEDORA_DEV_NO_COMPLETIONS=1` to disable.

## Re-running / adding pieces later

```bash
./setup-fedora-dev.sh --docker --sdkman   # adds only what's missing
./setup-fedora-dev.sh --skip-upgrade      # fast re-run without the full upgrade
./setup-fedora-dev.sh --only kitty,zsh    # iterate on one area
FLATPAK_APPS="org.videolan.VLC" ./setup-fedora-dev.sh --only repos
```

PATH entries live in a managed block (`# >>> fedora-dev-setup >>>`) in `~/.bashrc`/`~/.zshrc`. Kitty owns `fedora-dev.conf` (overwritten per run); your `kitty.conf` is preserved with the `include` on top so your lines win.

## Files touched

| Path | How |
|---|---|
| `/etc/dnf/dnf.conf` | `max_parallel_downloads=10`, `fastestmirror=True` (via sudo) |
| `~/.bashrc`, `~/.zshrc` | Managed PATH/completions block upserted; OMZ theme/plugins enforced in `.zshrc` |
| `~/.zshrc \| ~/.bashrc \| kitty.conf` | First-run originals kept as `*.pre-fedora-dev.bak` (never overwritten) |
| `~/.config/kitty/fedora-dev.conf` | Managed Catppuccin/JetBrainsMono config (overwritten per run) |
| `~/.oh-my-zsh`, `~/.pyenv`, `~/.cargo`, `~/.local/bin`, `~/go` | User-space tools (cloned or updated per run) |
| `~/fedora-dev-setup.log` | Appended every run with a `Run started` header |

## Troubleshooting

Exit codes: `0` success · `1` pre-flight/argument failure · `2` run-as-root/sudo failure. Unexpected errors print the failing line number — check the log tail, or re-run with `-v`.

| Symptom | Cause → fix |
|---|---|
| `Unsupported OS` (exit 1) | Not Fedora → run on Fedora Workstation |
| `No active internet` (exit 1) | Connect and re-run |
| `Insufficient disk space` (exit 1) | Free space or lower `MIN_DISK_GB=<n>` |
| `Unknown --only section` (exit 1) | Typo — valid tokens listed in the error |
| Font download warnings | Transient/upstream layout change — re-run; kitty falls back to monospace meanwhile; pin with `NERD_FONTS_REF=<tag>` |
| Oh My Zsh reported MISSING | Network blip during install — re-run (or `--only zsh`) |
| `id -nG` / `$SHELL` unchanged | Group/shell changes need logout + login |
| `p10k configure` never ran | `-y`/no-TTY run — launch it manually in kitty |
| Slow re-runs | `--skip-upgrade`, or `--only` the section you're iterating on |
| Completions slow the shell | `export FEDORA_DEV_NO_COMPLETIONS=1` |
| Manual health checks | `dnf repolist`, `flatpak remote-list`, `systemctl status libvirtd`, `id -nG` |

## Relation to `backup-system.sh`

This repo has two complementary scripts: `setup-fedora-dev.sh` builds the environment (this guide); `backup-system.sh` captures an existing machine into a timestamped backup + generated `restore-system.sh` (see `README.md`). Typical flow: set up once → back up → restore on the next machine → re-run setup to converge.
