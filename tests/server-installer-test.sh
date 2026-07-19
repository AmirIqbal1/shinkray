#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP_DIR="$(mktemp -d)"
INSTALL_ROOT="${TEMP_DIR}/install-root"
MEDIA_ROOT="${TEMP_DIR}/media"
BACKEND='http://127.0.0.1:8787'

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'server installer test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file did not contain: $expected"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file unexpectedly contained: $unexpected"
  fi
}

mkdir -p -- "$INSTALL_ROOT" "$MEDIA_ROOT"

old_status="$(cat <<EOF
https://test-host.example.ts.net/
|-- / proxy ${BACKEND}

https://test-host.example.ts.net:9443/
|-- / proxy http://127.0.0.1:9000
EOF
)"
after_config="$(cat <<EOF
https://test-host.example.ts.net:8443/
|-- / proxy ${BACKEND}

https://test-host.example.ts.net/
|-- / proxy ${BACKEND}

https://test-host.example.ts.net:9443/
|-- / proxy http://127.0.0.1:9000
EOF
)"
after_off="$(cat <<EOF
https://test-host.example.ts.net:8443/
|-- / proxy ${BACKEND}

https://test-host.example.ts.net:9443/
|-- / proxy http://127.0.0.1:9000
EOF
)"
ss_443='LISTEN 0 4096 100.64.0.1:443 0.0.0.0:* users:(("tailscaled",pid=100,fd=10))'

printf 'Testing safe migration from Tailscale HTTPS 443 to 8443...\n'
SHRINKRAY_INSTALL_TEST_MODE=1 \
SHRINKRAY_INSTALL_ROOT="$INSTALL_ROOT" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS="$old_status" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_AFTER_CONFIG="$after_config" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_AFTER_OFF="$after_off" \
SHRINKRAY_INSTALL_TEST_SS_OUTPUT="$ss_443" \
  "$ROOT_DIR/install-server.sh" \
    --source-dir "$ROOT_DIR" \
    --user testuser \
    --root "Movies=$MEDIA_ROOT" \
    --non-interactive >"${TEMP_DIR}/migration.out" 2>&1
cp -- "$INSTALL_ROOT/shrinkray-install-test.log" "${TEMP_DIR}/migration.commands"

config="$INSTALL_ROOT/etc/shrinkray/server.conf"
launcher="$INSTALL_ROOT/usr/local/libexec/shrinkray-server-launcher"
assert_contains "$config" "SHRINKRAY_PORT='8787'"
assert_contains "$config" "SHRINKRAY_TAILSCALE_HTTPS_PORT='8443'"
assert_contains "$launcher" "--listen \"127.0.0.1:\${SHRINKRAY_PORT}\""
assert_not_contains "$launcher" '0.0.0.0'
assert_contains "${TEMP_DIR}/migration.out" 'https://test-host.example.ts.net:8443/'
assert_contains "${TEMP_DIR}/migration.out" 'Coolify/reverse-proxy HTTPS remains available on:'
assert_contains "${TEMP_DIR}/migration.commands" "COMMAND: tailscale serve --https=8443 --bg --yes ${BACKEND}"
assert_contains "${TEMP_DIR}/migration.commands" 'COMMAND: tailscale serve --https=443 off'
assert_contains "${TEMP_DIR}/migration.commands" "COMMAND: curl --fail --silent --show-error ${BACKEND}/api/health"
assert_not_contains "${TEMP_DIR}/migration.commands" 'tailscale serve reset'
assert_not_contains "${TEMP_DIR}/migration.commands" 'tailscale funnel'
assert_not_contains "${TEMP_DIR}/migration.commands" '--https=9443 off'

new_line="$(grep -nF 'COMMAND: tailscale serve --https=8443 --bg --yes' "${TEMP_DIR}/migration.commands" | cut -d: -f1)"
old_line="$(grep -nF 'COMMAND: tailscale serve --https=443 off' "${TEMP_DIR}/migration.commands" | cut -d: -f1)"
[ "$new_line" -lt "$old_line" ] || fail 'the new 8443 listener was not configured before the old 443 listener was removed'

printf 'Testing that an existing correct 8443 listener is unchanged...\n'
SHRINKRAY_INSTALL_TEST_MODE=1 \
SHRINKRAY_INSTALL_ROOT="$INSTALL_ROOT" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS="$after_off" \
  "$ROOT_DIR/install-server.sh" \
    --source-dir "$ROOT_DIR" \
    --non-interactive >"${TEMP_DIR}/existing.out" 2>&1
cp -- "$INSTALL_ROOT/shrinkray-install-test.log" "${TEMP_DIR}/existing.commands"
assert_contains "${TEMP_DIR}/existing.out" 'leaving that listener unchanged'
assert_not_contains "${TEMP_DIR}/existing.commands" 'tailscale serve --https=8443 --bg'
assert_not_contains "${TEMP_DIR}/existing.commands" 'tailscale serve --https=9443 off'

printf 'Testing that an unrelated listener blocks a conflicting HTTPS port...\n'
conflict_status="$(cat <<'EOF'
https://test-host.example.ts.net:9443/
|-- / proxy http://127.0.0.1:9000
EOF
)"
set +e
SHRINKRAY_INSTALL_TEST_MODE=1 \
SHRINKRAY_INSTALL_ROOT="$INSTALL_ROOT" \
SHRINKRAY_INSTALL_TEST_SERVICE_ACTIVE=1 \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS="$conflict_status" \
SHRINKRAY_INSTALL_TEST_SS_OUTPUT='LISTEN 0 4096 100.64.0.1:9443 0.0.0.0:* users:(("tailscaled",pid=100,fd=11))' \
  "$ROOT_DIR/install-server.sh" \
    --source-dir "$ROOT_DIR" \
    --tailscale-https-port 9443 \
    --non-interactive >"${TEMP_DIR}/conflict.out" 2>&1
conflict_exit=$?
set -e
[ "$conflict_exit" -ne 0 ] || fail 'an unrelated listener on the requested HTTPS port was overwritten'
cp -- "$INSTALL_ROOT/shrinkray-install-test.log" "${TEMP_DIR}/conflict.commands"
assert_contains "${TEMP_DIR}/conflict.out" 'Choose another unused port with --tailscale-https-port'
assert_not_contains "${TEMP_DIR}/conflict.commands" 'tailscale serve --https=9443 --bg'
assert_contains "$config" "SHRINKRAY_TAILSCALE_HTTPS_PORT='8443'"

printf 'Testing that Tailscale HTTPS port 443 is always rejected...\n'
set +e
SHRINKRAY_INSTALL_TEST_MODE=1 \
SHRINKRAY_INSTALL_ROOT="${TEMP_DIR}/reject-443" \
  "$ROOT_DIR/install-server.sh" \
    --source-dir "$ROOT_DIR" \
    --tailscale-https-port 443 >"${TEMP_DIR}/reject-443.out" 2>&1
reject_exit=$?
set -e
[ "$reject_exit" -ne 0 ] || fail 'installer accepted Tailscale HTTPS port 443'
assert_contains "${TEMP_DIR}/reject-443.out" 'Refusing Tailscale HTTPS port 443'

printf 'Testing that an unrelated backend listener is never replaced...\n'
set +e
SHRINKRAY_INSTALL_TEST_MODE=1 \
SHRINKRAY_INSTALL_ROOT="$INSTALL_ROOT" \
SHRINKRAY_INSTALL_TEST_SS_OUTPUT='LISTEN 0 4096 127.0.0.1:8787 0.0.0.0:* users:(("nginx",pid=200,fd=12))' \
  "$ROOT_DIR/install-server.sh" \
    --source-dir "$ROOT_DIR" \
    --non-interactive >"${TEMP_DIR}/backend-conflict.out" 2>&1
backend_conflict_exit=$?
set -e
[ "$backend_conflict_exit" -ne 0 ] || fail 'installer accepted an unrelated backend listener'
assert_contains "${TEMP_DIR}/backend-conflict.out" 'Backend port 8787 is already owned by another process'

doctor="$INSTALL_ROOT/usr/local/bin/shrinkray-server-doctor"
printf 'Testing read-only doctor conflict detection...\n'
set +e
SHRINKRAY_INSTALL_TEST_MODE=1 \
SHRINKRAY_INSTALL_ROOT="$INSTALL_ROOT" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS="$old_status" \
SHRINKRAY_INSTALL_TEST_SS_OUTPUT="$ss_443" \
SHRINKRAY_INSTALL_TEST_DOCKER_PS='coolify-proxy' \
SHRINKRAY_INSTALL_TEST_COOLIFY_RUNNING=true \
  "$doctor" >"${TEMP_DIR}/doctor.out" 2>&1
doctor_exit=$?
set -e
[ "$doctor_exit" -ne 0 ] || fail 'doctor did not detect the old Shrinkray 443 listener'
cp -- "$INSTALL_ROOT/shrinkray-doctor-test.log" "${TEMP_DIR}/doctor.commands"
assert_contains "${TEMP_DIR}/doctor.out" 'Shrinkray is still using Tailscale HTTPS port 443'
assert_contains "${TEMP_DIR}/doctor.out" 'Coolify proxy container is running'
if grep -Eq 'COMMAND: (systemctl restart|tailscale serve --https|docker (stop|restart|rm))' "${TEMP_DIR}/doctor.commands"; then
  fail 'normal doctor mode issued a mutating command'
fi

printf 'Testing constrained doctor repair...\n'
SHRINKRAY_INSTALL_TEST_MODE=1 \
SHRINKRAY_INSTALL_ROOT="$INSTALL_ROOT" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS="$old_status" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_AFTER_CONFIG="$after_config" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_AFTER_OFF="$after_off" \
SHRINKRAY_INSTALL_TEST_SS_OUTPUT="$ss_443" \
  "$doctor" --repair >"${TEMP_DIR}/doctor-repair.out" 2>&1
cp -- "$INSTALL_ROOT/shrinkray-doctor-test.log" "${TEMP_DIR}/doctor-repair.commands"
assert_contains "${TEMP_DIR}/doctor-repair.commands" "COMMAND: tailscale serve --https=8443 --bg --yes ${BACKEND}"
assert_contains "${TEMP_DIR}/doctor-repair.commands" 'COMMAND: tailscale serve --https=443 off'
assert_not_contains "${TEMP_DIR}/doctor-repair.commands" 'tailscale serve reset'
assert_not_contains "${TEMP_DIR}/doctor-repair.commands" 'tailscale funnel'
if grep -Eq 'COMMAND: (docker (stop|restart|rm)|systemctl (stop|restart) (docker|coolify|jellyfin))' "${TEMP_DIR}/doctor-repair.commands"; then
  fail 'doctor repair attempted to modify Docker, Coolify, or Jellyfin'
fi

printf 'Testing targeted uninstaller Serve removal...\n'
SHRINKRAY_INSTALL_TEST_MODE=1 \
SHRINKRAY_INSTALL_ROOT="$INSTALL_ROOT" \
SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS="$after_off" \
  "$ROOT_DIR/uninstall-server.sh" --remove-tailscale-serve --yes >"${TEMP_DIR}/uninstall.out" 2>&1
assert_contains "$INSTALL_ROOT/shrinkray-uninstall-test.log" 'COMMAND: tailscale serve --https=8443 off'
assert_not_contains "$INSTALL_ROOT/shrinkray-uninstall-test.log" '--https=9443 off'
assert_not_contains "$INSTALL_ROOT/shrinkray-uninstall-test.log" 'tailscale serve reset'

if grep -Eq 'tailscale (serve reset|funnel)|docker (stop|restart|rm)|systemctl .*\b(coolify|docker|jellyfin)\b' \
  "$ROOT_DIR/install-server.sh" "$ROOT_DIR/uninstall-server.sh" "$ROOT_DIR/scripts/shrinkray-server-doctor.sh"; then
  fail 'managed scripts contain a forbidden Tailscale, Docker, Coolify, or Jellyfin mutation'
fi

printf 'Server installer safety tests passed.\n'
