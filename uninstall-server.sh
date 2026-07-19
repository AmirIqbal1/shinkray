#!/usr/bin/env bash
#
# Remove the managed Shrinkray dashboard without touching media or Tailscale.
#
set -euo pipefail

TEST_MODE=false
INSTALL_ROOT=""
TEST_LOG=""
if [ "${SHRINKRAY_INSTALL_TEST_MODE:-0}" = 1 ]; then
  TEST_MODE=true
  INSTALL_ROOT="${SHRINKRAY_INSTALL_ROOT:-}"
  [ -n "$INSTALL_ROOT" ] || {
    printf 'xx  SHRINKRAY_INSTALL_ROOT is required in uninstaller test mode.\n' >&2
    exit 1
  }
  [[ "$INSTALL_ROOT" == /* ]] || {
    printf 'xx  SHRINKRAY_INSTALL_ROOT must be an absolute path.\n' >&2
    exit 1
  }
  mkdir -p -- "$INSTALL_ROOT"
  INSTALL_ROOT="$(realpath -e -- "$INSTALL_ROOT")"
  [ "$INSTALL_ROOT" != / ] || {
    printf 'xx  Uninstaller test mode refuses to use / as SHRINKRAY_INSTALL_ROOT.\n' >&2
    exit 1
  }
  TEST_LOG="${INSTALL_ROOT}/shrinkray-uninstall-test.log"
  : > "$TEST_LOG"
  chmod 0600 "$TEST_LOG"
fi

CONFIG_DIR="${INSTALL_ROOT}/etc/shrinkray"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
SERVICE_FILE="${INSTALL_ROOT}/etc/systemd/system/shrinkray.service"
LAUNCHER_FILE="${INSTALL_ROOT}/usr/local/libexec/shrinkray-server-launcher"
SERVER_BIN="${INSTALL_ROOT}/usr/local/bin/shrinkray-server"
SHRINKRAY_BIN="${INSTALL_ROOT}/usr/local/bin/shrinkray"
DOCTOR_BIN="${INSTALL_ROOT}/usr/local/bin/shrinkray-server-doctor"
STATE_DIR="${INSTALL_ROOT}/var/lib/shrinkray"

PURGE_STATE=false
REMOVE_TAILSCALE_SERVE=false
REMOVE_CLI=false
ASSUME_YES=false
DRY_RUN=false

say() {
  if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    printf '==> %s\n' "$*"
  fi
}
warn() { printf '!!  %s\n' "$*" >&2; }
die() { printf 'xx  %s\n' "$*" >&2; exit 1; }

record_command() {
  local argument
  [ "$TEST_MODE" = true ] || return 0
  {
    printf 'COMMAND:'
    for argument in "$@"; do
      printf ' %q' "$argument"
    done
    printf '\n'
  } >> "$TEST_LOG"
}

usage() {
  cat <<'EOF'
Uninstall the managed Shrinkray server dashboard.

USAGE:
  sudo ./uninstall-server.sh [options]

OPTIONS:
  --purge-state             Also remove /var/lib/shrinkray (confirmation required)
  --remove-tailscale-serve  Remove Serve only when its sole route is Shrinkray
  --remove-cli              Also remove /usr/local/bin/shrinkray
  --yes                     Confirm destructive optional actions
  --dry-run                 Show intended actions without changing anything
  -h, --help                Show this help

By default, media, state, the Bash CLI, Tailscale, its login, and its Serve
configuration are preserved.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge-state) PURGE_STATE=true ;;
    --remove-tailscale-serve) REMOVE_TAILSCALE_SERVE=true ;;
    --remove-cli) REMOVE_CLI=true ;;
    --yes) ASSUME_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown uninstaller option: $1 (see --help)" ;;
  esac
  shift
done

if [ "$DRY_RUN" = false ] && [ "$TEST_MODE" = false ] && [ "$(id -u)" -ne 0 ]; then
  die "Production uninstallation must run as root. Re-run with sudo, or use --dry-run."
fi

run_systemctl() {
  record_command systemctl "$@"
  if [ "$TEST_MODE" = true ]; then
    return 0
  fi
  systemctl "$@"
}

run_tailscale() {
  record_command tailscale "$@"
  if [ "$TEST_MODE" = true ]; then
    if [ "${1-}" = serve ] && [ "${2-}" = status ] && [ "${3-}" = --json ]; then
      printf '%s\n' "${SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_JSON:-{}}"
    elif [ "${1-}" = serve ] && [ "${2-}" = status ]; then
      printf '%s\n' "${SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS:-No serve config}"
    fi
    return 0
  fi
  tailscale "$@"
}

configured_ports() {
  BACKEND_PORT=""
  TAILSCALE_HTTPS_PORT="8443"
  if [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
    BACKEND_PORT="$(sed -n -E "s/^SHRINKRAY_PORT='([0-9]+)'$/\\1/p" "$CONFIG_FILE" | head -n 1)"
    local configured_https
    configured_https="$(sed -n -E "s/^SHRINKRAY_TAILSCALE_HTTPS_PORT='([0-9]+)'$/\\1/p" "$CONFIG_FILE" | head -n 1)"
    [ -z "$configured_https" ] || TAILSCALE_HTTPS_PORT="$configured_https"
  fi
  [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] && [ "$BACKEND_PORT" -ge 1 ] && [ "$BACKEND_PORT" -le 65535 ] || return 1
  [[ "$TAILSCALE_HTTPS_PORT" =~ ^[0-9]+$ ]] && [ "$TAILSCALE_HTTPS_PORT" -ge 1 ] && [ "$TAILSCALE_HTTPS_PORT" -le 65535 ] || return 1
}

serve_is_empty() {
  local status="$1"
  [ -z "$status" ] || printf '%s' "$status" | grep -Eiq 'no serve (config|configuration)|not configured'
}

serve_listener_exists() {
  local status="$1" wanted_port="$2"
  printf '%s\n' "$status" | awk -v wanted="$wanted_port" '
    function listener_port(line, host) {
      host=line; sub(/^[[:space:]]*https:\/\//, "", host); sub(/[[:space:]\/].*$/, "", host)
      if (host ~ /:[0-9]+$/) { sub(/^.*:/, "", host); return host }
      return 443
    }
    /^[[:space:]]*https:\/\// && listener_port($0) == wanted { found=1 }
    END { exit(found ? 0 : 1) }
  '
}

serve_port_is_only_backend() {
  local status="$1" wanted_port="$2" backend="$3"
  printf '%s\n' "$status" | awk -v wanted="$wanted_port" -v backend="$backend" '
    function listener_port(line, host) {
      host=line; sub(/^[[:space:]]*https:\/\//, "", host); sub(/[[:space:]\/].*$/, "", host)
      if (host ~ /:[0-9]+$/) { sub(/^.*:/, "", host); return host }
      return 443
    }
    /^[[:space:]]*https:\/\// { port=listener_port($0); next }
    port == wanted && /^[[:space:]]*\|--/ { routes++; if (index($0, backend)) matches++ }
    END { exit(routes == 1 && matches == 1 ? 0 : 1) }
  '
}

remove_tailscale_serve_if_owned() {
  local backend status status_json
  [ "$REMOVE_TAILSCALE_SERVE" = true ] || return 0
  if [ "$TEST_MODE" = false ]; then
    command -v tailscale >/dev/null 2>&1 || die "Cannot inspect Tailscale Serve because the tailscale command is unavailable."
  fi
  configured_ports || die "Cannot safely identify the configured Shrinkray backend and Tailscale HTTPS ports."
  backend="http://127.0.0.1:${BACKEND_PORT}"
  status="$(run_tailscale serve status 2>&1)" || die "Could not inspect the current Tailscale Serve configuration."
  status_json="$(run_tailscale serve status --json 2>&1)" || die "Could not inspect the JSON Tailscale Serve configuration."
  [ -n "$status_json" ] || die "Tailscale Serve returned empty JSON status; refusing to remove anything."
  say "Current Tailscale Serve status:"
  printf '%s\n' "$status"
  if serve_is_empty "$status"; then
    say "No Tailscale Serve configuration exists; nothing will be removed."
  elif ! serve_listener_exists "$status" "$TAILSCALE_HTTPS_PORT"; then
    say "No listener exists on configured HTTPS port $TAILSCALE_HTTPS_PORT; unrelated Serve routes were preserved."
  elif ! serve_port_is_only_backend "$status" "$TAILSCALE_HTTPS_PORT" "$backend"; then
    die "The configured HTTPS port $TAILSCALE_HTTPS_PORT does not clearly belong only to Shrinkray; refusing to remove it."
  elif [ "$DRY_RUN" = true ]; then
    say "Would disable only Shrinkray's HTTPS port $TAILSCALE_HTTPS_PORT listener for $backend."
  else
    run_tailscale serve --https="$TAILSCALE_HTTPS_PORT" off || die "Could not disable the Shrinkray Tailscale Serve endpoint."
    say "Removed Shrinkray's Tailscale Serve listener on HTTPS port $TAILSCALE_HTTPS_PORT."
  fi
}

confirm_state_purge() {
  [ "$PURGE_STATE" = true ] || return 0
  if [ "$ASSUME_YES" = true ]; then
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    say "Would require confirmation before purging $STATE_DIR."
    return
  fi
  [ -t 0 ] || die "--purge-state requires confirmation; rerun with --yes in a non-interactive session."
  local answer
  read -r -p "Permanently remove $STATE_DIR? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "State purge cancelled; no uninstall changes were made." ;;
  esac
}

remove_file() {
  local path="$1"
  if [ "$DRY_RUN" = true ]; then
    say "Would remove $path"
  else
    rm -f -- "$path"
  fi
}

confirm_state_purge
remove_tailscale_serve_if_owned

if [ "$DRY_RUN" = true ]; then
  say "Would stop and disable shrinkray.service."
else
  run_systemctl stop shrinkray || warn "shrinkray.service was not running or could not be stopped."
  run_systemctl disable shrinkray || warn "shrinkray.service was not enabled or could not be disabled."
fi

remove_file "$SERVICE_FILE"
remove_file "$LAUNCHER_FILE"
remove_file "$SERVER_BIN"
remove_file "$DOCTOR_BIN"
remove_file "$CONFIG_FILE"
[ "$REMOVE_CLI" = false ] || remove_file "$SHRINKRAY_BIN"

if [ "$PURGE_STATE" = true ]; then
  if [ "$DRY_RUN" = true ]; then
    say "Would remove only $STATE_DIR; media roots would remain untouched."
  else
    rm -rf -- "$STATE_DIR"
  fi
else
  say "Preserving state directory: $STATE_DIR"
fi

if [ "$DRY_RUN" = true ]; then
  say "Would remove $CONFIG_DIR only if empty."
  say "Would run systemctl daemon-reload."
else
  rmdir -- "$CONFIG_DIR" 2>/dev/null || true
  run_systemctl daemon-reload
fi

say "Shrinkray server uninstall complete. Media roots, media files, Tailscale, and its login were not removed."
if [ "$REMOVE_TAILSCALE_SERVE" = false ]; then
  say "Tailscale Serve configuration was preserved."
fi
