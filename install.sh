#!/usr/bin/env bash
#
# shrinkray installer for Ubuntu and Linux Mint
#
# Local install (default):
#   curl -fsSL https://raw.githubusercontent.com/AmirIqbal1/shrinkray/main/install.sh | bash
# System install:
#   curl -fsSL https://raw.githubusercontent.com/AmirIqbal1/shrinkray/main/install.sh | bash -s -- --system
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/AmirIqbal1/shrinkray/main"
SYSTEM_MODE=false
TEMP_DIR=""

say() { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die() { printf 'xx  %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Install shrinkray on Ubuntu or Linux Mint.

USAGE:
  ./install.sh [--system]
  curl -fsSL https://raw.githubusercontent.com/AmirIqbal1/shrinkray/main/install.sh | bash

OPTIONS:
  --system    Install to /usr/local/bin using sudo
  -h, --help  Show this help

Without --system, shrinkray is installed to ~/.local/bin.
EOF
}

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --system) SYSTEM_MODE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown installer option: $1 (see --help)" ;;
  esac
done

detect_distribution() {
  [ -r /etc/os-release ] || die "Cannot identify this Linux distribution (/etc/os-release is missing)."

  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu)
      say "Detected Ubuntu ${VERSION_ID:-unknown version}."
      ;;
    linuxmint)
      say "Detected Linux Mint ${VERSION_ID:-unknown version}."
      ;;
    *)
      die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. This installer supports Ubuntu and Linux Mint."
      ;;
  esac
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "Administrator access is required. Install sudo or run this installer as root."
  fi
}

install_ffmpeg() {
  if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    say "ffmpeg and ffprobe are already installed."
    return
  fi

  say "ffmpeg is missing; installing it with apt-get."
  run_as_root apt-get update
  run_as_root apt-get install -y ffmpeg

  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg installation finished, but ffmpeg is still not available."
  command -v ffprobe >/dev/null 2>&1 || die "ffmpeg installation finished, but ffprobe is still not available."
}

find_local_source() {
  local script_source script_dir candidate
  script_source="${BASH_SOURCE[0]:-}"

  # When bash reads this installer from stdin, BASH_SOURCE does not name a
  # regular install.sh. Only trust a shrinkray file beside a real installer.
  [ -n "$script_source" ] && [ -f "$script_source" ] || return 1
  script_dir="$(cd -- "$(dirname -- "$script_source")" && pwd -P)"
  candidate="${script_dir}/shrinkray"
  [ -s "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

login_shell_path_file() {
  local user_name login_shell shell_name
  user_name="$(id -un)"
  login_shell=""
  if command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$user_name" | cut -d: -f7)"
  fi
  login_shell="${login_shell:-${SHELL:-/bin/sh}}"
  shell_name="$(basename -- "$login_shell")"

  case "$shell_name" in
    bash) printf '%s\n' "${HOME}/.bashrc" ;;
    zsh) printf '%s\n' "${HOME}/.zshrc" ;;
    fish) printf '%s\n' "${HOME}/.config/fish/config.fish" ;;
    *) printf '%s\n' "${HOME}/.profile" ;;
  esac
}

update_path() {
  local shell_file shell_dir path_line

  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*)
      say "${HOME}/.local/bin is already on PATH."
      return
      ;;
  esac

  shell_file="$(login_shell_path_file)"
  shell_dir="$(dirname -- "$shell_file")"
  mkdir -p -- "$shell_dir"

  if [ "$(basename -- "${SHELL:-/bin/sh}")" = "fish" ] || [[ "$shell_file" == */fish/config.fish ]]; then
    # These lines are written literally for the user's shell to expand later.
    # shellcheck disable=SC2016
    path_line='fish_add_path --path "$HOME/.local/bin"'
  else
    # shellcheck disable=SC2016
    path_line='export PATH="$HOME/.local/bin:$PATH"'
  fi

  if [ -f "$shell_file" ] && grep -Fqx -- "$path_line" "$shell_file"; then
    say "PATH entry already exists in ${shell_file}."
    return
  fi

  printf '\n%s\n' "$path_line" >> "$shell_file"
  say "Added ${HOME}/.local/bin to PATH in ${shell_file}."
  say "Open a new terminal, or run: source \"${shell_file}\""
}

say "shrinkray installer"
detect_distribution
install_ffmpeg

TEMP_DIR="$(mktemp -d)"
SOURCE_FILE="${TEMP_DIR}/shrinkray"

if LOCAL_SOURCE="$(find_local_source)"; then
  say "Installing from the cloned repository."
  cp -- "$LOCAL_SOURCE" "$SOURCE_FILE"
else
  command -v curl >/dev/null 2>&1 || die "curl is required to download shrinkray. Install it with: sudo apt-get install curl"
  say "Downloading shrinkray from AmirIqbal1/shrinkray."
  curl -fsSL "${REPO_RAW}/shrinkray" -o "$SOURCE_FILE" || die "Download failed. Check your network connection and try again."
fi

[ -s "$SOURCE_FILE" ] || die "The shrinkray download was empty; nothing was installed."
chmod +x "$SOURCE_FILE"

if [ "$SYSTEM_MODE" = true ]; then
  INSTALL_DIR="/usr/local/bin"
  run_as_root mkdir -p -- "$INSTALL_DIR"
  run_as_root install -m 0755 "$SOURCE_FILE" "${INSTALL_DIR}/shrinkray"
  say "Installed shrinkray system-wide at ${INSTALL_DIR}/shrinkray."
else
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p -- "$INSTALL_DIR"
  install -m 0755 "$SOURCE_FILE" "${INSTALL_DIR}/shrinkray"
  say "Installed shrinkray for this user at ${INSTALL_DIR}/shrinkray."
  update_path
fi

if [ -x "${INSTALL_DIR}/shrinkray" ]; then
  say "Success. Try: shrinkray doctor"
else
  die "Installation did not produce an executable at ${INSTALL_DIR}/shrinkray."
fi
