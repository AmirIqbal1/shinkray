#!/usr/bin/env bash
# Diagnose the managed Shrinkray server without changing the host by default.
set -euo pipefail

TEST_MODE=false
INSTALL_ROOT=""
TEST_LOG=""
if [ "${SHRINKRAY_INSTALL_TEST_MODE:-0}" = 1 ]; then
  TEST_MODE=true
  INSTALL_ROOT="${SHRINKRAY_INSTALL_ROOT:-}"
  [ -n "$INSTALL_ROOT" ] || {
    printf 'shrinkray-server-doctor: SHRINKRAY_INSTALL_ROOT is required in test mode.\n' >&2
    exit 1
  }
  [[ "$INSTALL_ROOT" == /* ]] || {
    printf 'shrinkray-server-doctor: test root must be absolute.\n' >&2
    exit 1
  }
  TEST_LOG="${INSTALL_ROOT}/shrinkray-doctor-test.log"
  : > "$TEST_LOG"
  chmod 0600 "$TEST_LOG"
fi

CONFIG_FILE="${INSTALL_ROOT}/etc/shrinkray/server.conf"
REPAIR=false
ISSUES=0
TEST_SERVE_STATUS="${SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS:-No serve config}"

usage() {
  cat <<'EOF'
Usage: shrinkray-server-doctor [--repair]

Without arguments, all checks are read-only. --repair may restart only the
Shrinkray service and safely repair Shrinkray-owned Tailscale Serve listeners.
EOF
}

case "${1-}" in
  "") ;;
  --repair) REPAIR=true ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'shrinkray-server-doctor: unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

if [ "$REPAIR" = true ] && [ "$TEST_MODE" = false ] && [ "$(id -u)" -ne 0 ]; then
  printf 'shrinkray-server-doctor: --repair must run as root.\n' >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
  printf 'shrinkray-server-doctor: managed configuration is missing: %s\n' "$CONFIG_FILE" >&2
  exit 1
fi
bash -n "$CONFIG_FILE" || {
  printf 'shrinkray-server-doctor: managed configuration is invalid.\n' >&2
  exit 1
}

SHRINKRAY_USER=""
# shellcheck disable=SC2034
SHRINKRAY_GROUP=""
SHRINKRAY_PORT=""
SHRINKRAY_TAILSCALE_HTTPS_PORT="8443"
# shellcheck disable=SC2034
SHRINKRAY_STATE_DIR=""
declare -a SHRINKRAY_ROOTS=()
# shellcheck disable=SC1090
. "$CONFIG_FILE"

[[ "$SHRINKRAY_PORT" =~ ^[0-9]+$ ]] || {
  printf 'shrinkray-server-doctor: invalid backend port in configuration.\n' >&2
  exit 1
}
if [ "${#SHRINKRAY_PORT}" -gt 5 ] || [ "$SHRINKRAY_PORT" -lt 1 ] || [ "$SHRINKRAY_PORT" -gt 65535 ]; then
  printf 'shrinkray-server-doctor: backend port is outside 1-65535.\n' >&2
  exit 1
fi
[[ "$SHRINKRAY_TAILSCALE_HTTPS_PORT" =~ ^[0-9]+$ ]] || {
  printf 'shrinkray-server-doctor: invalid Tailscale HTTPS port in configuration.\n' >&2
  exit 1
}
if [ "${#SHRINKRAY_TAILSCALE_HTTPS_PORT}" -gt 5 ] || [ "$SHRINKRAY_TAILSCALE_HTTPS_PORT" -lt 1 ] || [ "$SHRINKRAY_TAILSCALE_HTTPS_PORT" -gt 65535 ]; then
  printf 'shrinkray-server-doctor: Tailscale HTTPS port is outside 1-65535.\n' >&2
  exit 1
fi

backend="http://127.0.0.1:${SHRINKRAY_PORT}"

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

ok() { printf 'OK: %s\n' "$*"; }
info() { printf 'INFO: %s\n' "$*"; }
problem() { printf 'PROBLEM: %s\n' "$*" >&2; ISSUES=$((ISSUES + 1)); }

run_systemctl() {
  record_command systemctl "$@"
  if [ "$TEST_MODE" = true ]; then
    case "${1-}" in
      is-active) [ "${SHRINKRAY_INSTALL_TEST_SERVICE_ACTIVE:-1}" = 1 ] ;;
      status) printf 'test shrinkray.service status\n' ;;
      *) return 0 ;;
    esac
    return
  fi
  systemctl "$@"
}

run_curl() {
  record_command curl "$@"
  if [ "$TEST_MODE" = true ]; then
    [ "${SHRINKRAY_INSTALL_TEST_HEALTH_OK:-1}" = 1 ] || return 22
    printf '{"status":"ok"}\n'
    return
  fi
  curl "$@"
}

run_ss() {
  record_command ss "$@"
  if [ "$TEST_MODE" = true ]; then
    printf '%s\n' "${SHRINKRAY_INSTALL_TEST_SS_OUTPUT:-}"
    return
  fi
  ss "$@"
}

run_tailscale() {
  record_command tailscale "$@"
  if [ "$TEST_MODE" = true ]; then
    if [ "${1-}" = status ] && [ "${2-}" = --json ]; then
      printf '%s\n' "${SHRINKRAY_INSTALL_TEST_TAILSCALE_STATUS_JSON:-{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"test-host.example.ts.net.\"}}}"
    elif [ "${1-}" = status ]; then
      printf '%s\n' "${SHRINKRAY_INSTALL_TEST_TAILSCALE_STATUS:-100.64.0.1 test-host test@example linux active}"
    elif [ "${1-}" = serve ] && [ "${2-}" = status ] && [ "${3-}" = --json ]; then
      printf '%s\n' "${SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_JSON:-{}}"
    elif [ "${1-}" = serve ] && [ "${2-}" = status ]; then
      printf '%s\n' "${TEST_SERVE_STATUS:-No serve config}"
    elif [ "${1-}" = serve ]; then
      if [ "${*: -1}" = off ]; then
        TEST_SERVE_STATUS="${SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_AFTER_OFF:-No serve config}"
      else
        TEST_SERVE_STATUS="${SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_AFTER_CONFIG:-https://test-host.example.ts.net:${SHRINKRAY_TAILSCALE_HTTPS_PORT}/
|-- / proxy ${backend}}"
      fi
    fi
    return 0
  fi
  tailscale "$@"
}

run_docker() {
  record_command docker "$@"
  if [ "$TEST_MODE" = true ]; then
    if [ "${1-}" = ps ]; then
      printf '%s\n' "${SHRINKRAY_INSTALL_TEST_DOCKER_PS:-}"
    elif [ "${1-}" = inspect ]; then
      printf '%s\n' "${SHRINKRAY_INSTALL_TEST_COOLIFY_RUNNING:-true}"
    fi
    return
  fi
  docker "$@"
}

as_service_user() {
  if [ "$TEST_MODE" = true ]; then
    "$@"
  elif [ "$(id -u)" -eq 0 ]; then
    runuser -u "$SHRINKRAY_USER" -- "$@"
  elif [ "$(id -un)" = "$SHRINKRAY_USER" ]; then
    "$@"
  else
    return 126
  fi
}

ss_port_lines() {
  local status="$1" port="$2"
  printf '%s\n' "$status" | awk -v suffix=":${port}" '$4 ~ (suffix "$")'
}

serve_listener_exists() {
  local status="$1" wanted_port="$2"
  printf '%s\n' "$status" | awk -v wanted="$wanted_port" '
    function port(line, host) {
      host=line; sub(/^[[:space:]]*https:\/\//, "", host); sub(/[[:space:]\/].*$/, "", host)
      if (host ~ /:[0-9]+$/) { sub(/^.*:/, "", host); return host }
      return 443
    }
    /^[[:space:]]*https:\/\// && port($0) == wanted { found=1 }
    END { exit(found ? 0 : 1) }
  '
}

serve_backend_at_port() {
  local status="$1" wanted_port="$2" wanted_backend="$3"
  printf '%s\n' "$status" | awk -v wanted="$wanted_port" -v backend="$wanted_backend" '
    function listener_port(line, host) {
      host=line; sub(/^[[:space:]]*https:\/\//, "", host); sub(/[[:space:]\/].*$/, "", host)
      if (host ~ /:[0-9]+$/) { sub(/^.*:/, "", host); return host }
      return 443
    }
    /^[[:space:]]*https:\/\// { port=listener_port($0); next }
    port == wanted && index($0, backend) { found=1 }
    END { exit(found ? 0 : 1) }
  '
}

serve_port_is_only_backend() {
  local status="$1" wanted_port="$2" wanted_backend="$3"
  printf '%s\n' "$status" | awk -v wanted="$wanted_port" -v backend="$wanted_backend" '
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

dns_name_from_json() {
  local json="$1" name
  name="$(printf '%s' "$json" | grep -Eom1 '"DNSName"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/^[^:]+:[[:space:]]*"([^"]+)"$/\1/')" || true
  printf '%s' "${name%.}"
}

backend_health_ok() {
  local response
  response="$(run_curl --fail --silent --show-error "${backend}/api/health")" || return 1
  printf '%s' "$response" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'
}

repair_now() {
  local serve_status ss_status port_lines
  [ "$SHRINKRAY_TAILSCALE_HTTPS_PORT" != 443 ] || {
    printf 'REPAIR REFUSED: configured Tailscale HTTPS port 443 is unsafe.\n' >&2
    return 1
  }
  [ "$SHRINKRAY_TAILSCALE_HTTPS_PORT" != "$SHRINKRAY_PORT" ] || {
    printf 'REPAIR REFUSED: backend and Tailscale HTTPS ports must be different.\n' >&2
    return 1
  }
  if ! run_systemctl is-active --quiet shrinkray || ! backend_health_ok; then
    info "Restarting only shrinkray.service."
    run_systemctl restart shrinkray || return 1
    backend_health_ok || {
      printf 'REPAIR REFUSED: local Shrinkray health still fails after restart.\n' >&2
      return 1
    }
  fi
  run_tailscale status --json | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"' || {
    printf 'REPAIR REFUSED: Tailscale is not connected.\n' >&2
    return 1
  }
  serve_status="$(run_tailscale serve status)" || return 1
  run_tailscale serve status --json >/dev/null || return 1
  ss_status="$(run_ss -ltnp)" || return 1
  port_lines="$(ss_port_lines "$ss_status" "$SHRINKRAY_PORT")"
  if [ -n "$port_lines" ] && ! printf '%s\n' "$port_lines" | grep -Fq 'shrinkray-serve'; then
    printf 'REPAIR REFUSED: backend port %s belongs to another process.\n' "$SHRINKRAY_PORT" >&2
    printf '%s\n' "$port_lines" >&2
    return 1
  fi
  if serve_listener_exists "$serve_status" "$SHRINKRAY_TAILSCALE_HTTPS_PORT" &&
     ! serve_backend_at_port "$serve_status" "$SHRINKRAY_TAILSCALE_HTTPS_PORT" "$backend"; then
    printf 'REPAIR REFUSED: HTTPS port %s belongs to another Serve route.\n' "$SHRINKRAY_TAILSCALE_HTTPS_PORT" >&2
    return 1
  fi
  port_lines="$(ss_port_lines "$ss_status" "$SHRINKRAY_TAILSCALE_HTTPS_PORT")"
  if [ -n "$port_lines" ] &&
     { ! serve_backend_at_port "$serve_status" "$SHRINKRAY_TAILSCALE_HTTPS_PORT" "$backend" || ! printf '%s\n' "$port_lines" | grep -Fqi tailscaled; }; then
    printf 'REPAIR REFUSED: HTTPS port %s is owned by another process.\n' "$SHRINKRAY_TAILSCALE_HTTPS_PORT" >&2
    printf '%s\n' "$port_lines" >&2
    return 1
  fi
  if ! serve_backend_at_port "$serve_status" "$SHRINKRAY_TAILSCALE_HTTPS_PORT" "$backend"; then
    info "Configuring Shrinkray on Tailscale HTTPS port $SHRINKRAY_TAILSCALE_HTTPS_PORT."
    run_tailscale serve --https="$SHRINKRAY_TAILSCALE_HTTPS_PORT" --bg --yes "$backend" || return 1
    serve_status="$(run_tailscale serve status)" || return 1
    run_tailscale serve status --json >/dev/null || return 1
    serve_backend_at_port "$serve_status" "$SHRINKRAY_TAILSCALE_HTTPS_PORT" "$backend" || return 1
  fi
  if serve_backend_at_port "$serve_status" 443 "$backend"; then
    if serve_port_is_only_backend "$serve_status" 443 "$backend"; then
      info "Removing only the old Shrinkray Tailscale HTTPS port 443 listener."
      run_tailscale serve --https=443 off || return 1
      run_tailscale serve status --json >/dev/null || return 1
    else
      printf 'REPAIR REFUSED: port 443 contains unrelated routes and was not changed.\n' >&2
      return 1
    fi
  fi
}

if [ "$REPAIR" = true ]; then
  repair_now || {
    printf 'Shrinkray repair stopped without resetting Serve, Docker, or media permissions.\n' >&2
    exit 1
  }
fi

printf 'Shrinkray server doctor\n\n'
if run_systemctl is-active --quiet shrinkray; then
  ok "shrinkray.service is active."
else
  problem "shrinkray.service is not active."
fi
run_systemctl status shrinkray --no-pager -l || true

if backend_health_ok; then
  ok "Local backend health passed at ${backend}/api/health."
else
  problem "Local backend health failed at ${backend}/api/health."
fi

ss_status="$(run_ss -ltnp 2>/dev/null)" || ss_status=""
for port in 443 "$SHRINKRAY_PORT" "$SHRINKRAY_TAILSCALE_HTTPS_PORT"; do
  lines="$(ss_port_lines "$ss_status" "$port")"
  if [ -n "$lines" ]; then
    info "TCP port $port listener:"
    printf '%s\n' "$lines"
  else
    info "TCP port $port has no visible listener."
  fi
done
backend_lines="$(ss_port_lines "$ss_status" "$SHRINKRAY_PORT")"
if [ -n "$backend_lines" ] && ! printf '%s\n' "$backend_lines" | grep -Fq 'shrinkray-serve'; then
  problem "Backend port $SHRINKRAY_PORT is owned by a process other than shrinkray-server."
fi
https_lines="$(ss_port_lines "$ss_status" "$SHRINKRAY_TAILSCALE_HTTPS_PORT")"
if [ -n "$https_lines" ] && ! printf '%s\n' "$https_lines" | grep -Fqi tailscaled; then
  problem "Tailscale HTTPS port $SHRINKRAY_TAILSCALE_HTTPS_PORT is owned by another process."
fi

tailscale_text="$(run_tailscale status 2>&1)" || tailscale_text=""
tailscale_json="$(run_tailscale status --json 2>/dev/null)" || tailscale_json=""
printf '%s\n' "$tailscale_text"
if printf '%s' "$tailscale_json" | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
  ok "Tailscale is connected."
else
  problem "Tailscale is not connected."
fi

serve_status="$(run_tailscale serve status 2>&1)" || serve_status=""
serve_json="$(run_tailscale serve status --json 2>/dev/null)" || serve_json=""
info "Tailscale Serve status:"
printf '%s\n' "$serve_status"
[ -n "$serve_json" ] || problem "Tailscale Serve JSON status is unavailable."
if [ "$SHRINKRAY_TAILSCALE_HTTPS_PORT" = 443 ]; then
  problem "The configured Tailscale HTTPS port is 443; change it to 8443 or another unused non-443 port."
fi
if [ "$SHRINKRAY_TAILSCALE_HTTPS_PORT" = "$SHRINKRAY_PORT" ]; then
  problem "The backend and Tailscale HTTPS ports are not separated."
fi
if serve_backend_at_port "$serve_status" "$SHRINKRAY_TAILSCALE_HTTPS_PORT" "$backend"; then
  ok "Shrinkray uses Tailscale HTTPS port $SHRINKRAY_TAILSCALE_HTTPS_PORT."
else
  problem "Shrinkray is not served on configured Tailscale HTTPS port $SHRINKRAY_TAILSCALE_HTTPS_PORT."
fi
if serve_backend_at_port "$serve_status" 443 "$backend"; then
  problem "Shrinkray is still using Tailscale HTTPS port 443 and may block the host reverse proxy."
else
  ok "Shrinkray does not claim Tailscale HTTPS port 443."
fi

dns_name="$(dns_name_from_json "$tailscale_json")"
if [[ "$dns_name" == *.ts.net ]]; then
  if [ "$SHRINKRAY_TAILSCALE_HTTPS_PORT" = 443 ]; then
    browser_url="https://${dns_name}/"
  else
    browser_url="https://${dns_name}:${SHRINKRAY_TAILSCALE_HTTPS_PORT}/"
  fi
  ok "Private browser URL: $browser_url"
else
  problem "Could not form the private browser URL from the Tailscale DNS name."
fi

if [ "$TEST_MODE" = true ] || command -v docker >/dev/null 2>&1; then
  docker_names="$(run_docker ps --format '{{.Names}}' 2>/dev/null)" || docker_names=""
  if printf '%s\n' "$docker_names" | grep -Fxq coolify-proxy; then
    if [ "$(run_docker inspect -f '{{.State.Running}}' coolify-proxy 2>/dev/null)" = true ]; then
      ok "Coolify proxy container is running."
    else
      problem "The coolify-proxy container exists but is not running."
    fi
  else
    info "No running coolify-proxy container was detected."
  fi
else
  info "Docker is not installed; Coolify proxy check skipped."
fi

for root_spec in "${SHRINKRAY_ROOTS[@]}"; do
  if [[ "$root_spec" == /* ]]; then
    root_path="$root_spec"
  else
    root_path="${root_spec#*=}"
  fi
  if as_service_user test -x "$root_path" && as_service_user test -r "$root_path" && as_service_user test -w "$root_path"; then
    ok "Media root is traversable, readable, and writable by $SHRINKRAY_USER: $root_path"
  else
    problem "Media root access failed for $SHRINKRAY_USER: $root_path"
  fi
done

if [ "$ISSUES" -gt 0 ]; then
  printf '\nDoctor found %s issue(s).\n' "$ISSUES" >&2
  exit 1
fi
printf '\nAll Shrinkray server checks passed.\n'
