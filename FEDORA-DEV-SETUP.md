# Fedora Dev Setup — Step-by-Step Usage Guide

How to use `setup-fedora-dev.sh` to turn a fresh Fedora Workstation install into a polyglot dev environment.

## 1. Prerequisites

- Fedora Workstation (other editions warn but continue; non-Fedora exits 1).
- Regular user with `sudo` rights. Do **not** run as root (exits 2).
- Internet access, ≥ 20 GB free disk.
- Optional: `snapper` or `timeshift` installed for a pre-change snapshot.

## 2. Get the script

```bash
cd ~/Dev/projects/system-backup-script
chmod +x setup-fedora-dev.sh
./setup-fedora-dev.sh --help
```

## 3. Pick your options

| Command | Effect |
|---|---|
| `./setup-fedora-dev.sh` | Defaults (no Docker, no SDKMAN!) |
| `./setup-fedora-dev.sh --docker` | Also installs Docker CE, adds you to `docker` group |
| `./setup-fedora-dev.sh --sdkman` | Also installs SDKMAN! to `~/.sdkman` |
| `./setup-fedora-dev.sh --docker --sdkman` | Both |
| `./setup-fedora-dev.sh -y` | Non-interactive (still asks sudo password once) |

Env-var equivalents: `INSTALL_DOCKER=1`, `INSTALL_SDKMAN=1`, `NONINTERACTIVE=1`.

## 4. Run it

```bash
./setup-fedora-dev.sh
```

1. Enter your `sudo` password once when prompted (kept alive in background).
2. Wait through: pre-flight checks → DNF tuning → full `upgrade --refresh` → RPM Fusion + OpenH264 + Flathub → build tools / CLI / nvim + kitty (Catppuccin Mocha drop-in, JetBrainsMono Nerd 13, GNOME default) → zsh + Oh My Zsh + Powerlevel10k (dev plugins, Meslo font, `chsh` to zsh) → fnm+Node LTS, uv+pyenv, rustup, Go, JDK → podman (+ Docker if flagged) + libvirt → shell wiring → verification table.
3. The `p10k configure` wizard launches interactively (skipped with `-y` or no TTY — run `p10k configure` manually later). Your existing `~/.p10k.zsh` is never overwritten.
4. The script is idempotent — re-running only fills gaps.

## 5. Mandatory post-install steps

```bash
# 1. Log out and back in (activates docker/libvirt groups AND the new zsh default shell)
id -nG   # should eventually show docker and/or libvirt
echo $SHELL  # should end in /zsh

# 2. Open kitty (now the default terminal, Catppuccin Mocha, JetBrainsMono NF 13),
#    then configure the prompt if the wizard didn't run during setup
p10k configure   # only if the wizard didn't run during setup

# 3. Reload shell config (or open a new terminal)
source ~/.zshrc

# 4. Confirm runtimes
node --version && pnpm --version && yarn --version
uv --version && pyenv --versions
rustc --version && cargo --version
go version && echo $GOPATH
java -version
podman --version
```

## 6. Re-running / adding pieces later

```bash
./setup-fedora-dev.sh --docker --sdkman   # safe anytime; adds only what's missing
```

Shell PATH entries live in a managed block (`# >>> fedora-dev-setup >>>`) in `~/.bashrc` / `~/.zshrc` — replaced, never duplicated.

## 7. Logs and troubleshooting

- Full log: `~/fedora-dev-setup.log`
- Failure: the trap prints the failing line number; check the log tail.
- Common fixes: no internet (pre-flight exits 1), low disk (< 20 GB exits 1), run as root (exits 2) — re-run as your user.
- Verify manually: `dnf repolist`, `flatpak remote-list`, `systemctl status libvirtd`, `id -nG`.
