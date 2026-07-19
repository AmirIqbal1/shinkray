#!/usr/bin/env bash
#
# Install and manage the Shrinkray dashboard as a systemd service.
#
set -Eeuo pipefail

REPOSITORY_ARCHIVE="https://github.com/AmirIqbal1/shrinkray/archive/refs/heads/main.tar.gz"
TEST_MODE=false
INSTALL_ROOT=""
TEST_LOG=""
if [ "${SHRINKRAY_INSTALL_TEST_MODE:-0}" = 1 ]; then
  TEST_MODE=true
  INSTALL_ROOT="${SHRINKRAY_INSTALL_ROOT:-}"
  [ -n "$INSTALL_ROOT" ] || {
    printf 'xx  SHRINKRAY_INSTALL_ROOT is required in installer test mode.\n' >&2
    exit 1
  }
  [[ "$INSTALL_ROOT" == /* ]] || {
    printf 'xx  SHRINKRAY_INSTALL_ROOT must be an absolute path.\n' >&2
    exit 1
  }
  mkdir -p -- "$INSTALL_ROOT"
  INSTALL_ROOT="$(realpath -e -- "$INSTALL_ROOT")"
  [ "$INSTALL_ROOT" != / ] || {
    printf 'xx  Installer test mode refuses to use / as SHRINKRAY_INSTALL_ROOT.\n' >&2
    exit 1
  }
  TEST_LOG="${INSTALL_ROOT}/shrinkray-install-test.log"
  : > "$TEST_LOG"
  chmod 0600 "$TEST_LOG"
fi

CONFIG_DIR="${INSTALL_ROOT}/etc/shrinkray"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
STATE_DIR_DEFAULT="${INSTALL_ROOT}/var/lib/shrinkray"
LAUNCHER_FILE="${INSTALL_ROOT}/usr/local/libexec/shrinkray-server-launcher"
SERVICE_FILE="${INSTALL_ROOT}/etc/systemd/system/shrinkray.service"
SHRINKRAY_BIN="${INSTALL_ROOT}/usr/local/bin/shrinkray"
SERVER_BIN="${INSTALL_ROOT}/usr/local/bin/shrinkray-server"
DOCTOR_BIN="${INSTALL_ROOT}/usr/local/bin/shrinkray-server-doctor"

SERVICE_USER=""
SERVICE_GROUP=""
PORT="8787"
TAILSCALE_HTTPS_PORT="8443"
STATE_DIR="$STATE_DIR_DEFAULT"
SOURCE_DIR_ARG=""
TAILSCALE_URL=""
USER_EXPLICIT=false
PORT_EXPLICIT=false
TAILSCALE_HTTPS_PORT_EXPLICIT=false
ROOTS_SUPPLIED=false
SKIP_TAILSCALE=false
FORCE_TAILSCALE=false
NON_INTERACTIVE=false
DRY_RUN=false
TEMP_DIR=""
SOURCE_DIR=""
GO_BIN=""
GO_NEW_DIR=""
GO_BACKUP_DIR=""
GO_LINK_TMP=""
GO_INSTALL_IN_PROGRESS=false
MANAGED_CONFIG_FOUND=false
MANUAL_SERVICE_FOUND=false
FILES_REPLACED=false
INSTALL_SUCCEEDED=false
ROLLBACK_IN_PROGRESS=false
PREVIOUS_SERVICE_ACTIVE=false
PREVIOUS_PORT=""
BACKUP_DIR=""
DETECTED_TAILSCALE_URL=""
TEST_SERVE_STATUS="${SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS:-No serve config}"

declare -a REQUESTED_ROOTS=()
declare -a EXISTING_ROOTS=()
declare -a MANUAL_ROOTS=()
declare -a CONFIGURED_ROOTS=()
declare -a ROOT_LABELS=()
declare -a ROOT_IDS=()
declare -a ROOT_PATHS=()
declare -a PARSED_WORDS=()

say() {
  if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    printf '==> %s\n' "$*"
  fi
}
warn() { printf '!!  %s\n' "$*" >&2; }
die() {
  printf 'xx  %s\n' "$*" >&2
  if [ "$FILES_REPLACED" = true ] && [ "$ROLLBACK_IN_PROGRESS" = false ]; then
    rollback_installation || true
  fi
  exit 1
}

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
Install the Shrinkray server dashboard on Ubuntu or Linux Mint.

USAGE:
  sudo ./install-server.sh --user <username> --root <directory> [options]
  curl -fsSL https://raw.githubusercontent.com/AmirIqbal1/shrinkray/main/install-server.sh |
    sudo bash -s -- --user <username> --root "Movies=/media/movies"

OPTIONS:
  --user <username>          Account that runs shrinkray-server
  --root <path>              Media root (repeatable)
  --root "Name=/path"        Named media root (repeatable)
  --port <port>              Loopback HTTP port (default: 8787)
  --tailscale-https-port <port>
                             Private Tailscale HTTPS port (default: 8443)
  --skip-tailscale           Do not inspect or change Tailscale Serve
  --force-tailscale          Legacy acknowledgement; never bypasses port safety
  --tailscale-url <url>      Override the displayed/checked private HTTPS URL
  --source-dir <checkout>    Build from a local Shrinkray checkout
  --non-interactive          Never prompt for missing information
  --dry-run                  Validate and show changes without installing
  -h, --help                 Show this help

On updates, omitted roots, user, backend port, and Tailscale HTTPS port are
preserved from the managed configuration where available. Supplying --root
replaces the configured root list. Port 443 is never accepted for Shrinkray's
automatic Tailscale Serve configuration.
EOF
}

cleanup() {
	if [ "$FILES_REPLACED" = true ] && [ "$INSTALL_SUCCEEDED" = false ] && [ "$ROLLBACK_IN_PROGRESS" = false ]; then
		rollback_installation || true
	fi
	if [ "$GO_INSTALL_IN_PROGRESS" = true ]; then
		if { [ -z "$GO_NEW_DIR" ] || [ ! -e "$GO_NEW_DIR" ]; } && [ -e /usr/local/go ]; then
			rm -rf -- /usr/local/go
		fi
		if [ -n "$GO_BACKUP_DIR" ] && [ -d "$GO_BACKUP_DIR" ] && [ ! -e /usr/local/go ]; then
			mv -- "$GO_BACKUP_DIR" /usr/local/go || true
		fi
	elif [ -n "$GO_BACKUP_DIR" ] && [ -d "$GO_BACKUP_DIR" ] && [ -x /usr/local/go/bin/go ]; then
		rm -rf -- "$GO_BACKUP_DIR"
	fi
	if [ -n "$GO_NEW_DIR" ] && [ -e "$GO_NEW_DIR" ]; then
		rm -rf -- "$GO_NEW_DIR"
	fi
	if [ -n "$GO_LINK_TMP" ]; then
		rm -f -- "$GO_LINK_TMP"
	fi
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
installer_error() {
  local status="$1"
  trap - ERR
  if [ "$FILES_REPLACED" = true ] && [ "$ROLLBACK_IN_PROGRESS" = false ]; then
    rollback_installation || true
  fi
  exit "$status"
}
trap 'installer_error $?' ERR
trap cleanup EXIT HUP INT TERM

require_value() {
  local option="$1"
  local remaining="$2"
  local value="${3-}"
  [ "$remaining" -ge 2 ] || die "$option requires a value."
  [ -n "$value" ] || die "$option requires a non-empty value."
}

contains_control() {
  local value="$1"
  LC_ALL=C printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'
}

validate_text_argument() {
  local option="$1"
  local value="$2"
  if contains_control "$value"; then
    die "$option must not contain newlines or control characters."
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user)
      require_value "$1" "$#" "${2-}"
      validate_text_argument "$1" "$2"
      SERVICE_USER="$2"
      USER_EXPLICIT=true
      shift 2
      ;;
    --root)
      require_value "$1" "$#" "${2-}"
      validate_text_argument "$1" "$2"
      REQUESTED_ROOTS+=("$2")
      ROOTS_SUPPLIED=true
      shift 2
      ;;
    --port)
      require_value "$1" "$#" "${2-}"
      validate_text_argument "$1" "$2"
      PORT="$2"
      PORT_EXPLICIT=true
      shift 2
      ;;
    --tailscale-https-port)
      require_value "$1" "$#" "${2-}"
      validate_text_argument "$1" "$2"
      TAILSCALE_HTTPS_PORT="$2"
      TAILSCALE_HTTPS_PORT_EXPLICIT=true
      shift 2
      ;;
    --skip-tailscale)
      SKIP_TAILSCALE=true
      shift
      ;;
    --force-tailscale)
      FORCE_TAILSCALE=true
      shift
      ;;
    --tailscale-url)
      require_value "$1" "$#" "${2-}"
      validate_text_argument "$1" "$2"
      TAILSCALE_URL="$2"
      shift 2
      ;;
    --source-dir)
      require_value "$1" "$#" "${2-}"
      validate_text_argument "$1" "$2"
      SOURCE_DIR_ARG="$2"
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown installer option: $1 (see --help)" ;;
  esac
done

validate_port() {
  local port="$1" numeric
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port: $port (expected 1-65535)."
	[ "${#port}" -le 5 ] || die "Invalid port: $port (expected 1-65535)."
	numeric=$((10#$port))
	if [ "$numeric" -lt 1 ] || [ "$numeric" -gt 65535 ]; then
		die "Invalid port: $port (expected 1-65535)."
	fi
}

validate_port "$PORT"
validate_port "$TAILSCALE_HTTPS_PORT"
if [ "$TAILSCALE_HTTPS_PORT" = 443 ]; then
  die "Refusing Tailscale HTTPS port 443; it must remain available for the host reverse proxy. Choose --tailscale-https-port 8443 or another unused non-443 port."
fi
if [ "$SKIP_TAILSCALE" = true ] && [ "$FORCE_TAILSCALE" = true ]; then
  die "--skip-tailscale and --force-tailscale cannot be used together."
fi
if [ -n "$TAILSCALE_URL" ] && [[ "$TAILSCALE_URL" != https://* ]]; then
  die "--tailscale-url must be an https:// URL."
fi
if [ "$DRY_RUN" = false ] && [ "$TEST_MODE" = false ] && [ "$(id -u)" -ne 0 ]; then
  die "Production installation must run as root. Re-run with sudo, or use --dry-run."
fi
if [ "$TEST_MODE" = true ] && [ -z "$SOURCE_DIR_ARG" ]; then
  die "Installer test mode requires --source-dir; downloads are disabled."
fi

detect_platform() {
  if [ "$TEST_MODE" = true ]; then
    say "Installer test mode is active under $INSTALL_ROOT."
    return
  fi
  [ -r /etc/os-release ] || die "Cannot identify this Linux distribution (/etc/os-release is missing)."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|linuxmint) say "Detected ${PRETTY_NAME:-$ID}." ;;
    *) die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Use Ubuntu or Linux Mint." ;;
  esac
  [ -d /run/systemd/system ] || die "systemd is required and must be running as PID 1."
}

create_temp_dir() {
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shrinkray-server-install.XXXXXX")"
  chmod 0700 "$TEMP_DIR"
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fqx 'install ok installed'
}

install_dependencies() {
  local package
  local -a packages=(ca-certificates curl tar gzip ffmpeg coreutils iproute2 systemd util-linux)
  local -a missing=()
  if [ "$TEST_MODE" = true ]; then
    say "Test mode: package installation is disabled."
    record_command apt-get update
    record_command apt-get install -y "${packages[@]}"
    return
  fi
  command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query is required on supported systems."
  for package in "${packages[@]}"; do
    package_installed "$package" || missing+=("$package")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    say "Required system packages are already installed."
  elif [ "$DRY_RUN" = true ]; then
    say "Would install packages: ${missing[*]}"
  else
    say "Installing required packages: ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
  if [ "$DRY_RUN" = false ]; then
    local command_name
    for command_name in curl tar gzip ffmpeg ffprobe realpath ss systemctl runuser stat sha256sum; do
      command -v "$command_name" >/dev/null 2>&1 || die "Required command is unavailable after package installation: $command_name"
    done
  fi
}

validate_managed_config_file() {
	if [ -L "$CONFIG_DIR" ] || { [ "$TEST_MODE" = false ] && [ "$(stat -c '%u' "$CONFIG_DIR")" -ne 0 ]; }; then
		die "$CONFIG_DIR must be a root-owned, non-symlink directory."
	fi
	local directory_mode directory_mode_value
	directory_mode="$(stat -c '%a' "$CONFIG_DIR")"
	directory_mode_value=$((8#$directory_mode))
	(( (directory_mode_value & 8#022) == 0 )) || die "$CONFIG_DIR must not be writable by group or others."
  if [ ! -f "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
		die "$CONFIG_FILE must be a regular, non-symlink file."
	fi
  if [ "$TEST_MODE" = false ]; then
    [ "$(stat -c '%u' "$CONFIG_FILE")" -eq 0 ] || die "$CONFIG_FILE must be owned by root."
  fi
  local mode mode_value
  mode="$(stat -c '%a' "$CONFIG_FILE")"
  mode_value=$((8#$mode))
  (( (mode_value & 8#022) == 0 )) || die "$CONFIG_FILE must not be writable by group or others."
  bash -n "$CONFIG_FILE" || die "$CONFIG_FILE is not valid Bash; leaving it unchanged."
}

load_managed_config() {
	local config_directory_mode config_directory_mode_value
	if [ -L "$CONFIG_DIR" ] || { [ -e "$CONFIG_DIR" ] && [ ! -d "$CONFIG_DIR" ]; }; then
		die "$CONFIG_DIR must be a real directory, not a symlink or other file type."
	fi
	if [ -d "$CONFIG_DIR" ]; then
		if [ "$TEST_MODE" = false ]; then
			[ "$(stat -c '%u' "$CONFIG_DIR")" -eq 0 ] || die "$CONFIG_DIR must be owned by root."
		fi
		config_directory_mode="$(stat -c '%a' "$CONFIG_DIR")"
		config_directory_mode_value=$((8#$config_directory_mode))
		(( (config_directory_mode_value & 8#022) == 0 )) || die "$CONFIG_DIR must not be writable by group or others."
	fi
  [ -e "$CONFIG_FILE" ] || return 0
  validate_managed_config_file
  local SHRINKRAY_USER=""
  local SHRINKRAY_GROUP=""
  local SHRINKRAY_PORT=""
  local SHRINKRAY_TAILSCALE_HTTPS_PORT="8443"
  local SHRINKRAY_STATE_DIR=""
  local -a SHRINKRAY_ROOTS=()
  # This file is accepted only after root ownership, mode, and syntax checks.
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  [ -n "$SHRINKRAY_USER" ] || die "$CONFIG_FILE does not define SHRINKRAY_USER."
  [ -n "$SHRINKRAY_GROUP" ] || die "$CONFIG_FILE does not define SHRINKRAY_GROUP."
	validate_text_argument "configured user" "$SHRINKRAY_USER"
	validate_text_argument "configured group" "$SHRINKRAY_GROUP"
	validate_text_argument "configured state directory" "$SHRINKRAY_STATE_DIR"
  validate_port "$SHRINKRAY_PORT"
  validate_port "$SHRINKRAY_TAILSCALE_HTTPS_PORT"
  [[ "$SHRINKRAY_STATE_DIR" == /* ]] || die "$CONFIG_FILE has an invalid SHRINKRAY_STATE_DIR."
  [ "${#SHRINKRAY_ROOTS[@]}" -gt 0 ] || die "$CONFIG_FILE does not contain media roots."
  EXISTING_USER="$SHRINKRAY_USER"
  EXISTING_GROUP="$SHRINKRAY_GROUP"
  EXISTING_PORT="$SHRINKRAY_PORT"
  EXISTING_TAILSCALE_HTTPS_PORT="$SHRINKRAY_TAILSCALE_HTTPS_PORT"
  EXISTING_STATE_DIR="$SHRINKRAY_STATE_DIR"
  EXISTING_ROOTS=("${SHRINKRAY_ROOTS[@]}")
  MANAGED_CONFIG_FOUND=true
  say "Found existing managed server configuration."
}

service_value() {
  local key="$1"
  awk -v wanted="$key" '
    /^[[:space:]]*\[Service\][[:space:]]*$/ { in_service=1; next }
	/^[[:space:]]*\[/ { in_service=0; collecting=0 }
	collecting {
		line=$0
		sub("^[[:space:]]*", "", line)
		if (line ~ /\\[[:space:]]*$/) {
			sub(/\\[[:space:]]*$/, "", line)
			value=value line " "
		} else {
			value=value line
			collecting=0
		}
		next
	}
    in_service && $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      line=$0
      sub("^[[:space:]]*" wanted "[[:space:]]*=", "", line)
		if (line ~ /\\[[:space:]]*$/) {
			sub(/\\[[:space:]]*$/, "", line)
			value=line " "
			collecting=1
		} else {
			value=line
		}
    }
    END { if (value != "") print value }
  ' "$SERVICE_FILE"
}

split_systemd_words() {
  local input="$1"
  local state="plain" token="" character
  local token_started=false
  local i
  PARSED_WORDS=()
  for ((i = 0; i < ${#input}; i++)); do
    character="${input:i:1}"
    case "$state" in
      plain)
        case "$character" in
          " "|$'\t')
            if [ "$token_started" = true ]; then
              PARSED_WORDS+=("$token")
              token=""
              token_started=false
            fi
            ;;
          "'") state="single"; token_started=true ;;
          '"') state="double"; token_started=true ;;
          "\\") state="escape"; token_started=true ;;
          *) token+="$character"; token_started=true ;;
        esac
        ;;
      single)
        if [ "$character" = "'" ]; then state="plain"; else token+="$character"; fi
        ;;
      double)
        case "$character" in
          '"') state="plain" ;;
          "\\") state="double_escape" ;;
          *) token+="$character" ;;
        esac
        ;;
      escape) token+="$character"; state="plain" ;;
      double_escape) token+="$character"; state="double" ;;
    esac
  done
  [ "$state" = plain ] || return 1
  if [ "$token_started" = true ]; then
    PARSED_WORDS+=("$token")
  fi
}

migrate_manual_service() {
  [ "$MANAGED_CONFIG_FOUND" = false ] || return 0
  [ -f "$SERVICE_FILE" ] && [ ! -L "$SERVICE_FILE" ] || return 0
	if [ "$TEST_MODE" = false ]; then
		[ "$(stat -c '%u' "$SERVICE_FILE")" -eq 0 ] || die "$SERVICE_FILE must be owned by root before it can be migrated."
	fi
  grep -Fq 'shrinkray-server' "$SERVICE_FILE" || return 0
  local manual_user manual_group exec_start working_directory
  local index token value listen
  manual_user="$(service_value User)"
  manual_group="$(service_value Group)"
  exec_start="$(service_value ExecStart)"
  working_directory="$(service_value WorkingDirectory)"
  validate_text_argument "manual service User" "$manual_user"
  validate_text_argument "manual service Group" "$manual_group"
  validate_text_argument "manual service ExecStart" "$exec_start"
	validate_text_argument "manual service WorkingDirectory" "$working_directory"
  split_systemd_words "$exec_start" || die "Cannot safely parse ExecStart in $SERVICE_FILE. Supply --user and --root explicitly."
  [ "${#PARSED_WORDS[@]}" -gt 0 ] || return 0
  case "${PARSED_WORDS[0]#-}" in
    */shrinkray-server|shrinkray-server) ;;
    *) return 0 ;;
  esac
  MANUAL_USER="$manual_user"
  MANUAL_GROUP="$manual_group"
  MANUAL_PORT=""
  MANUAL_STATE_DIR=""
  MANUAL_ROOTS=()
  for ((index = 1; index < ${#PARSED_WORDS[@]}; index++)); do
    token="${PARSED_WORDS[index]}"
    case "$token" in
      --root)
        index=$((index + 1))
        [ "$index" -lt "${#PARSED_WORDS[@]}" ] || die "Manual service has --root without a value."
        MANUAL_ROOTS+=("${PARSED_WORDS[index]}")
        ;;
      --root=*) MANUAL_ROOTS+=("${token#--root=}") ;;
      --listen)
        index=$((index + 1))
        [ "$index" -lt "${#PARSED_WORDS[@]}" ] || die "Manual service has --listen without a value."
        listen="${PARSED_WORDS[index]}"
        MANUAL_PORT="${listen##*:}"
        ;;
      --listen=*) listen="${token#--listen=}"; MANUAL_PORT="${listen##*:}" ;;
      --state-dir)
        index=$((index + 1))
        [ "$index" -lt "${#PARSED_WORDS[@]}" ] || die "Manual service has --state-dir without a value."
        MANUAL_STATE_DIR="${PARSED_WORDS[index]}"
        ;;
      --state-dir=*) MANUAL_STATE_DIR="${token#--state-dir=}" ;;
    esac
  done
	if [ -z "$MANUAL_STATE_DIR" ] && [ -n "$working_directory" ]; then
		if split_systemd_words "$working_directory" && [ "${#PARSED_WORDS[@]}" -eq 1 ] && [[ "${PARSED_WORDS[0]}" == /* ]]; then
			MANUAL_STATE_DIR="${PARSED_WORDS[0]}"
		fi
  fi
  if [ -n "$MANUAL_PORT" ]; then validate_port "$MANUAL_PORT"; fi
  MANUAL_SERVICE_FOUND=true
  say "Found an existing manually configured Shrinkray service; its safe settings will be migrated."
}

valid_account_name() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]]
}

account_exists_non_root() {
  local account="$1" uid
  valid_account_name "$account" || return 1
  if [ "$TEST_MODE" = true ]; then
    [ "$account" != root ]
    return
  fi
  uid="$(id -u "$account" 2>/dev/null)" || return 1
  [ "$uid" -ne 0 ]
}

select_service_user() {
  if [ "$USER_EXPLICIT" = true ]; then
    :
  elif [ "$MANAGED_CONFIG_FOUND" = true ]; then
    SERVICE_USER="$EXISTING_USER"
    SERVICE_GROUP="$EXISTING_GROUP"
  elif [ "$MANUAL_SERVICE_FOUND" = true ] && [ -n "$MANUAL_USER" ]; then
    SERVICE_USER="$MANUAL_USER"
    SERVICE_GROUP="$MANUAL_GROUP"
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && account_exists_non_root "$SUDO_USER"; then
    SERVICE_USER="$SUDO_USER"
  elif [ "$NON_INTERACTIVE" = false ] && [ -t 0 ]; then
    read -r -p "User account for shrinkray-server: " SERVICE_USER
    validate_text_argument "service user" "$SERVICE_USER"
  else
    die "No service user could be selected. Supply --user <username>."
  fi
  account_exists_non_root "$SERVICE_USER" || die "Service user does not exist or is root: $SERVICE_USER"
  if [ -z "$SERVICE_GROUP" ] || [ "$USER_EXPLICIT" = true ]; then
    if [ "$TEST_MODE" = true ]; then
      SERVICE_GROUP="$SERVICE_USER"
    else
      SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
    fi
  fi
  valid_account_name "$SERVICE_GROUP" || die "Invalid service group: $SERVICE_GROUP"
  if [ "$TEST_MODE" = false ]; then
    getent group "$SERVICE_GROUP" >/dev/null 2>&1 || die "Service group does not exist: $SERVICE_GROUP"
  fi
}

select_preserved_settings() {
  if [ "$PORT_EXPLICIT" = false ]; then
    if [ "$MANAGED_CONFIG_FOUND" = true ]; then
      PORT="$EXISTING_PORT"
    elif [ "$MANUAL_SERVICE_FOUND" = true ] && [ -n "$MANUAL_PORT" ]; then
      PORT="$MANUAL_PORT"
    fi
  fi
  validate_port "$PORT"
  if [ "$TAILSCALE_HTTPS_PORT_EXPLICIT" = false ] && [ "$MANAGED_CONFIG_FOUND" = true ]; then
    if [ "$EXISTING_TAILSCALE_HTTPS_PORT" = 443 ]; then
      TAILSCALE_HTTPS_PORT=8443
      warn "Migrating legacy configured Tailscale HTTPS port 443 to the safe default 8443."
    else
      TAILSCALE_HTTPS_PORT="$EXISTING_TAILSCALE_HTTPS_PORT"
    fi
  fi
  validate_port "$TAILSCALE_HTTPS_PORT"
  [ "$TAILSCALE_HTTPS_PORT" != 443 ] || die "Refusing Tailscale HTTPS port 443; choose --tailscale-https-port 8443 or another unused non-443 port."
  [ "$TAILSCALE_HTTPS_PORT" != "$PORT" ] || die "The backend port and Tailscale HTTPS port must be different."
  if [ "$MANAGED_CONFIG_FOUND" = true ]; then
    STATE_DIR="$EXISTING_STATE_DIR"
  elif [ "$MANUAL_SERVICE_FOUND" = true ] && [ -n "$MANUAL_STATE_DIR" ]; then
    STATE_DIR="$MANUAL_STATE_DIR"
  fi
  if [ "$TEST_MODE" = true ] && [[ "$STATE_DIR" == /var/lib || "$STATE_DIR" == /var/lib/* ]]; then
    STATE_DIR="${INSTALL_ROOT}${STATE_DIR}"
  fi
  if [[ "$STATE_DIR" != /* ]] || [ "$STATE_DIR" = / ]; then
		die "Invalid state directory: $STATE_DIR"
	fi
	if [ -L "$STATE_DIR" ] || { [ -e "$STATE_DIR" ] && [ ! -d "$STATE_DIR" ]; }; then
		die "State directory must be a real directory, not a symlink or other file type: $STATE_DIR"
	fi
  if [ "$ROOTS_SUPPLIED" = true ]; then
    CONFIGURED_ROOTS=("${REQUESTED_ROOTS[@]}")
  elif [ "$MANAGED_CONFIG_FOUND" = true ]; then
    CONFIGURED_ROOTS=("${EXISTING_ROOTS[@]}")
  elif [ "$MANUAL_SERVICE_FOUND" = true ] && [ "${#MANUAL_ROOTS[@]}" -gt 0 ]; then
    CONFIGURED_ROOTS=("${MANUAL_ROOTS[@]}")
  else
    die "At least one --root is required for the first installation."
  fi
}

trim_spaces() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
	value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+/ /g')"
  printf '%s' "$value"
}

automatic_label() {
  local base words word label=""
  local -a parts=()
  base="$(basename -- "$1")"
  words="${base//_/ }"
  words="${words//-/ }"
  read -r -a parts <<< "$words"
  for word in "${parts[@]}"; do
    if [ "${#word}" -le 3 ]; then
      word="${word^^}"
    else
      word="${word^}"
    fi
    label+="${label:+ }${word}"
  done
  [ -n "$label" ] || label="Root"
  printf '%s' "$label"
}

generated_root_id() {
  local label="$1" id
  id="$(printf '%s' "$label" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$id" ]; then
    id="root-$(printf '%s' "$label" | sha256sum | cut -c1-8)"
  fi
  printf '%s' "$id"
}

permission_failure() {
  local root="$1"
  warn "Service user '$SERVICE_USER' cannot safely use media root: $root"
  warn "Path details: owner=$(stat -c '%U' "$root") group=$(stat -c '%G' "$root") mode=$(stat -c '%A (%a)' "$root")"
  if [ "$TEST_MODE" = true ]; then
    warn "Service user memberships: test user/group ${SERVICE_USER}:${SERVICE_GROUP}"
  else
    warn "Service user memberships: $(id "$SERVICE_USER")"
  fi
  warn "No ownership, mode, or ACL changes were made to the media directory."
}

as_service_user() {
	if [ "$TEST_MODE" = true ]; then
		"$@"
		return
	fi
	if [ "$(id -u)" -eq 0 ]; then
		runuser -u "$SERVICE_USER" -- "$@"
	elif [ "$(id -un)" = "$SERVICE_USER" ]; then
		"$@"
	else
		return 126
	fi
}

verify_root_permissions() {
  local root="$1" test_file
  if ! as_service_user test -x "$root" ||
     ! as_service_user test -r "$root" ||
     ! as_service_user test -w "$root"; then
    permission_failure "$root"
    return 1
  fi
	if [ "$DRY_RUN" = true ]; then
		say "Would verify create/remove access in media root: $root"
		return 0
	fi
	if ! test_file="$(as_service_user mktemp "${root}/.shrinkray-install-test.XXXXXX")"; then
    permission_failure "$root"
    return 1
  fi
  if ! as_service_user rm -f -- "$test_file"; then
    rm -f -- "$test_file"
    permission_failure "$root"
    return 1
  fi
}

validate_roots() {
  local spec label root canonical id existing_path existing_label existing_id
  local -a seen_paths=() seen_labels=() seen_ids=()
  ROOT_LABELS=()
  ROOT_IDS=()
  ROOT_PATHS=()
  for spec in "${CONFIGURED_ROOTS[@]}"; do
    validate_text_argument "media root" "$spec"
    if [[ "$spec" == /* ]]; then
      root="$spec"
      label=""
    elif [[ "$spec" == *=/* ]]; then
      label="$(trim_spaces "${spec%%=*}")"
      root="${spec#*=}"
      [ -n "$label" ] || die "Media root display name must not be empty: $spec"
    else
      die "Media root must be an absolute path or Name=/absolute/path: $spec"
    fi
    [[ "$root" == /* ]] || die "Media root path must be absolute: $root"
    [ -d "$root" ] || die "Media root is not an existing directory: $root"
    canonical="$(realpath -e -- "$root")" || die "Could not resolve media root: $root"
	validate_text_argument "canonical media root" "$canonical"
    [ "$canonical" != / ] || die "Refusing to use / as a media root."
    [ -n "$label" ] || label="$(automatic_label "$canonical")"
    validate_text_argument "media root label" "$label"
    id="$(generated_root_id "$label")"
    for existing_path in "${seen_paths[@]}"; do
      [ "$canonical" != "$existing_path" ] || die "Duplicate canonical media root: $canonical"
      case "${canonical}/" in "${existing_path}/"*) die "Overlapping media roots: $existing_path and $canonical" ;; esac
      case "${existing_path}/" in "${canonical}/"*) die "Overlapping media roots: $canonical and $existing_path" ;; esac
    done
    for existing_label in "${seen_labels[@]}"; do
      [ "$label" != "$existing_label" ] || die "Duplicate media root label: $label"
    done
    for existing_id in "${seen_ids[@]}"; do
      [ "$id" != "$existing_id" ] || die "Duplicate generated media root ID: $id"
    done
    verify_root_permissions "$canonical" || die "Media root permission validation failed."
    seen_paths+=("$canonical")
    seen_labels+=("$label")
    seen_ids+=("$id")
    ROOT_PATHS+=("$canonical")
    ROOT_LABELS+=("$label")
    ROOT_IDS+=("$id")
  done
  [ "${#ROOT_PATHS[@]}" -gt 0 ] || die "At least one media root is required."
}

validate_source_tree() {
  local source="$1"
  [ -f "$source/go.mod" ] || die "Source tree is missing go.mod: $source"
  [ -f "$source/shrinkray" ] || die "Source tree is missing shrinkray: $source"
  [ -d "$source/cmd/shrinkray-server" ] || die "Source tree is missing cmd/shrinkray-server: $source"
  [ -f "$source/scripts/shrinkray-server-doctor.sh" ] || die "Source tree is missing scripts/shrinkray-server-doctor.sh: $source"
}

prepare_source() {
  if [ -n "$SOURCE_DIR_ARG" ]; then
    [[ "$SOURCE_DIR_ARG" == /* ]] || SOURCE_DIR_ARG="$(pwd -P)/$SOURCE_DIR_ARG"
    SOURCE_DIR="$(realpath -e -- "$SOURCE_DIR_ARG")" || die "Could not resolve --source-dir: $SOURCE_DIR_ARG"
		validate_text_argument "canonical source directory" "$SOURCE_DIR"
    validate_source_tree "$SOURCE_DIR"
    say "Building from local checkout: $SOURCE_DIR"
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    say "Would download $REPOSITORY_ARCHIVE"
    SOURCE_DIR=""
    return
  fi
  local archive
  archive="${TEMP_DIR}/shrinkray-main.tar.gz"
  say "Downloading Shrinkray source from the main branch."
  curl --fail --silent --show-error --location "$REPOSITORY_ARCHIVE" --output "$archive"
  mkdir -m 0700 "${TEMP_DIR}/source"
  tar -xzf "$archive" -C "${TEMP_DIR}/source"
  SOURCE_DIR="${TEMP_DIR}/source/shrinkray-main"
  validate_source_tree "$SOURCE_DIR"
}

version_at_least() {
  local installed="$1" required="$2" first
  first="$(printf '%s\n%s\n' "$installed" "$required" | sort -V | head -n 1)"
  [ "$first" = "$required" ]
}

install_official_go() {
  local machine go_arch latest archive checksum expected actual extracted new_dir backup_dir link_tmp
  machine="$(uname -m)"
  case "$machine" in
    x86_64) go_arch="amd64" ;;
    aarch64|arm64) go_arch="arm64" ;;
    *) die "Official Go installation supports amd64 and arm64, not: $machine" ;;
  esac
  latest="$(curl --fail --silent --show-error --location 'https://go.dev/VERSION?m=text' | sed -n '1p')"
  [[ "$latest" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Could not determine the latest stable Go version."
  archive="${TEMP_DIR}/${latest}.linux-${go_arch}.tar.gz"
  checksum="${archive}.sha256"
  say "Downloading official ${latest} for linux/${go_arch}."
  curl --fail --silent --show-error --location "https://go.dev/dl/${latest}.linux-${go_arch}.tar.gz" --output "$archive"
  curl --fail --silent --show-error --location "https://go.dev/dl/${latest}.linux-${go_arch}.tar.gz.sha256" --output "$checksum"
  expected="$(awk 'NR==1 {print $1}' "$checksum")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "Official Go checksum response was invalid."
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "Go archive checksum verification failed; installation stopped."
  extracted="${TEMP_DIR}/go-extracted"
  mkdir -m 0700 "$extracted"
  tar -xzf "$archive" -C "$extracted"
  [ -x "$extracted/go/bin/go" ] || die "Downloaded Go archive did not contain the Go toolchain."
	new_dir="/usr/local/go.new.$$"
	backup_dir="/usr/local/go.previous.$$"
  rm -rf -- "$new_dir" "$backup_dir"
  mv -- "$extracted/go" "$new_dir"
	GO_NEW_DIR="$new_dir"
	GO_BACKUP_DIR="$backup_dir"
	GO_INSTALL_IN_PROGRESS=true
  if [ -e /usr/local/go ]; then
    mv -- /usr/local/go "$backup_dir"
  fi
  if ! mv -- "$new_dir" /usr/local/go; then
    [ ! -e "$backup_dir" ] || mv -- "$backup_dir" /usr/local/go
    die "Could not install Go under /usr/local/go."
  fi
	install -d -o root -g root -m 0755 /usr/local/bin
  link_tmp="/usr/local/bin/.go-link.$$"
	GO_LINK_TMP="$link_tmp"
  ln -s /usr/local/go/bin/go "$link_tmp"
  mv -fT -- "$link_tmp" /usr/local/bin/go
	GO_LINK_TMP=""
	GO_INSTALL_IN_PROGRESS=false
  rm -rf -- "$backup_dir"
	GO_BACKUP_DIR=""
	GO_NEW_DIR=""
  GO_BIN="/usr/local/bin/go"
}

ensure_go() {
  local required installed=""
  [ -n "$SOURCE_DIR" ] || return 0
  required="$(awk '$1 == "go" {print $2; exit}' "$SOURCE_DIR/go.mod")"
  [[ "$required" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Could not read a valid Go version from go.mod."
  if command -v go >/dev/null 2>&1; then
    GO_BIN="$(command -v go)"
    installed="$($GO_BIN version | awk '{print $3}' | sed 's/^go//')"
  fi
	if [[ "$installed" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && version_at_least "$installed" "$required"; then
    say "Using Go $installed from $GO_BIN (go.mod requires $required)."
  elif [ "$TEST_MODE" = true ]; then
    die "Installer test mode requires an already installed Go toolchain at least as new as $required."
  elif [ "$DRY_RUN" = true ]; then
    say "Would install the latest stable official Go (go.mod requires $required)."
    GO_BIN=""
  else
    install_official_go
		installed="$($GO_BIN version | awk '{print $3}' | sed 's/^go//')"
		version_at_least "$installed" "$required" || die "Latest stable Go $installed does not satisfy go.mod requirement $required."
		say "Installed Go $installed from the verified official archive."
  fi
}

build_and_validate() {
  [ -n "$SOURCE_DIR" ] || {
    say "Source download and build skipped in dry-run mode."
    return
  }
  [ -n "$GO_BIN" ] || {
    say "Build skipped because a sufficient Go toolchain is not installed."
    return
  }
  local build_dir server_version
  build_dir="${TEMP_DIR}/build"
  mkdir -m 0700 "$build_dir"
  say "Building shrinkray-server."
  (
    cd -- "$SOURCE_DIR"
    GOCACHE="${TEMP_DIR}/go-cache" GOPATH="${TEMP_DIR}/go-path" "$GO_BIN" build -trimpath \
      -o "${build_dir}/shrinkray-server" ./cmd/shrinkray-server
  )
	server_version="$("${build_dir}/shrinkray-server" --version)"
  [[ "$server_version" == shrinkray-server\ v* ]] || die "Built server failed its version check."
  bash -n "$SOURCE_DIR/shrinkray"
  bash -n "$SOURCE_DIR/scripts/shrinkray-server-doctor.sh"
  install -m 0755 "$SOURCE_DIR/shrinkray" "${build_dir}/shrinkray"
  install -m 0755 "$SOURCE_DIR/scripts/shrinkray-server-doctor.sh" "${build_dir}/shrinkray-server-doctor"
  say "Validated $server_version and the Bash CLI."
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

write_config_candidate() {
  local target="$1" index
  {
    printf 'SHRINKRAY_USER=%s\n' "$(shell_quote "$SERVICE_USER")"
    printf 'SHRINKRAY_GROUP=%s\n' "$(shell_quote "$SERVICE_GROUP")"
    printf 'SHRINKRAY_PORT=%s\n' "$(shell_quote "$PORT")"
    printf 'SHRINKRAY_TAILSCALE_HTTPS_PORT=%s\n' "$(shell_quote "$TAILSCALE_HTTPS_PORT")"
    printf 'SHRINKRAY_STATE_DIR=%s\n' "$(shell_quote "$STATE_DIR")"
    printf 'SHRINKRAY_ROOTS=(\n'
    for ((index = 0; index < ${#ROOT_PATHS[@]}; index++)); do
      printf '  %s\n' "$(shell_quote "${ROOT_LABELS[index]}=${ROOT_PATHS[index]}")"
    done
    printf ')\n'
  } > "$target"
  chmod 0644 "$target"
  bash -n "$target" || die "Generated configuration failed Bash syntax validation."
}

write_launcher_candidate() {
  local target="$1"
  cat > "$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail

readonly config_file=$(shell_quote "$CONFIG_FILE")
[ -r "\$config_file" ] || {
  printf 'shrinkray-server-launcher: missing configuration: %s\n' "\$config_file" >&2
  exit 1
}
# shellcheck source=/etc/shrinkray/server.conf
. "\$config_file"

args=(
  --listen "127.0.0.1:\${SHRINKRAY_PORT}"
  --shrinkray-bin $(shell_quote "$SHRINKRAY_BIN")
  --state-dir "\${SHRINKRAY_STATE_DIR}"
)
for root in "\${SHRINKRAY_ROOTS[@]}"; do
  args+=(--root "\$root")
done

exec $(shell_quote "$SERVER_BIN") "\${args[@]}"
EOF
  chmod 0755 "$target"
  bash -n "$target" || die "Generated launcher failed Bash syntax validation."
}

systemd_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '"%s"' "$value"
}

write_service_candidate() {
  local target="$1" root
  {
    cat <<EOF
[Unit]
Description=Shrinkray media compression dashboard
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=$(systemd_quote "$LAUNCHER_FILE")
WorkingDirectory=$(systemd_quote "$STATE_DIR")
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillMode=control-group
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
UMask=0027
ReadWritePaths=$(systemd_quote "$STATE_DIR")
EOF
    for root in "${ROOT_PATHS[@]}"; do
      printf 'ReadWritePaths=%s\n' "$(systemd_quote "$root")"
    done
    cat <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
  } > "$target"
  chmod 0644 "$target"
}

run_systemctl() {
  record_command systemctl "$@"
  if [ "$TEST_MODE" = true ]; then
    case "${1-}" in
      is-active)
        [ "${SHRINKRAY_INSTALL_TEST_SERVICE_ACTIVE:-0}" = 1 ] || [ "${TEST_SERVICE_ACTIVE:-false}" = true ]
        ;;
      enable|restart|start)
        TEST_SERVICE_ACTIVE=true
        ;;
      stop|disable)
        TEST_SERVICE_ACTIVE=false
        ;;
    esac
    return
  fi
  systemctl "$@"
}

print_service_diagnostics() {
  if [ "$TEST_MODE" = true ]; then
    record_command systemctl status shrinkray --no-pager -l
    record_command journalctl -u shrinkray -n 100 --no-pager
    return
  fi
  systemctl status shrinkray --no-pager -l >&2 || true
  journalctl -u shrinkray -n 100 --no-pager >&2 || true
}

declare -a MANAGED_TARGETS=(
  "$SHRINKRAY_BIN"
  "$SERVER_BIN"
  "$DOCTOR_BIN"
  "$LAUNCHER_FILE"
  "$CONFIG_FILE"
  "$SERVICE_FILE"
)
declare -a BACKUP_EXISTED=()

backup_managed_files() {
  local index target
  BACKUP_DIR="${TEMP_DIR}/managed-backup"
  mkdir -m 0700 "$BACKUP_DIR"
  BACKUP_EXISTED=()
  for ((index = 0; index < ${#MANAGED_TARGETS[@]}; index++)); do
    target="${MANAGED_TARGETS[index]}"
    if [ -e "$target" ] || [ -L "$target" ]; then
      cp -a -- "$target" "${BACKUP_DIR}/${index}"
      BACKUP_EXISTED+=(true)
    else
      BACKUP_EXISTED+=(false)
    fi
  done
  PREVIOUS_SERVICE_ACTIVE=false
  if run_systemctl is-active --quiet shrinkray; then
    PREVIOUS_SERVICE_ACTIVE=true
  fi
  if [ "$MANAGED_CONFIG_FOUND" = true ]; then
    PREVIOUS_PORT="$EXISTING_PORT"
  elif [ "$MANUAL_SERVICE_FOUND" = true ]; then
    PREVIOUS_PORT="$MANUAL_PORT"
  fi
  say "Backed up existing managed files before replacement."
}

restore_managed_file() {
  local backup="$1" target="$2" parent temporary
  parent="$(dirname -- "$target")"
  mkdir -p -- "$parent"
  temporary="$(mktemp "${parent}/.shrinkray-rollback.XXXXXX")"
  rm -f -- "$temporary"
  cp -a -- "$backup" "$temporary"
  mv -fT -- "$temporary" "$target"
}

verify_previous_health() {
  [ "$PREVIOUS_SERVICE_ACTIVE" = true ] || return 0
  [ -n "$PREVIOUS_PORT" ] || {
    warn "Rollback restored the previous service, but its health port was not discoverable."
    return 0
  }
  if [ "$TEST_MODE" = true ]; then
    record_command curl --fail --silent --show-error "http://127.0.0.1:${PREVIOUS_PORT}/api/health"
    return
  fi
  local health_file="${TEMP_DIR}/rollback-health.json"
  for _ in $(seq 1 40); do
    if curl --fail --silent --show-error "http://127.0.0.1:${PREVIOUS_PORT}/api/health" --output "$health_file" &&
       grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' "$health_file"; then
      return 0
    fi
    sleep 0.25
  done
  warn "The previous service was restarted, but its local health check failed."
  return 1
}

rollback_installation() {
  local index target
  [ "$FILES_REPLACED" = true ] || return 0
  ROLLBACK_IN_PROGRESS=true
  warn "Installation failed after file replacement; rolling back."
  run_systemctl stop shrinkray || true
  for ((index = 0; index < ${#MANAGED_TARGETS[@]}; index++)); do
    target="${MANAGED_TARGETS[index]}"
    if [ "${BACKUP_EXISTED[index]:-false}" = true ]; then
      restore_managed_file "${BACKUP_DIR}/${index}" "$target" || warn "Could not restore $target"
    else
      rm -f -- "$target" || warn "Could not remove newly installed file: $target"
    fi
  done
  run_systemctl daemon-reload || true
  if [ "$PREVIOUS_SERVICE_ACTIVE" = true ]; then
    run_systemctl restart shrinkray || warn "Could not restart the previous shrinkray.service."
    verify_previous_health || true
  fi
  FILES_REPLACED=false
  ROLLBACK_IN_PROGRESS=false
  warn "Rollback completed; state, media, and Tailscale configuration were not removed."
}

atomic_install() {
  local source="$1" target="$2" mode="$3" temporary
  temporary="$(mktemp "${target}.tmp.XXXXXX")"
  if [ "$TEST_MODE" = true ]; then
    if ! install -m "$mode" "$source" "$temporary"; then
      rm -f -- "$temporary"
      return 1
    fi
  elif ! install -o root -g root -m "$mode" "$source" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  mv -fT -- "$temporary" "$target"
}

install_managed_files() {
  local build_dir="${TEMP_DIR}/build"
  if [ "$TEST_MODE" = true ]; then
    install -d -m 0755 "$(dirname -- "$SHRINKRAY_BIN")" "$(dirname -- "$LAUNCHER_FILE")" "$CONFIG_DIR" "$(dirname -- "$SERVICE_FILE")"
    install -d -m 0700 "$STATE_DIR_DEFAULT"
    if [ "$STATE_DIR" != "$STATE_DIR_DEFAULT" ]; then
      install -d -m 0700 "$STATE_DIR"
    fi
  else
    install -d -o root -g root -m 0755 /usr/local/bin /usr/local/libexec "$CONFIG_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$STATE_DIR_DEFAULT"
    if [ "$STATE_DIR" != "$STATE_DIR_DEFAULT" ]; then
      install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$STATE_DIR"
    fi
  fi
  FILES_REPLACED=true
  atomic_install "${build_dir}/shrinkray" "$SHRINKRAY_BIN" 0755 || die "Could not install $SHRINKRAY_BIN atomically."
  atomic_install "${build_dir}/shrinkray-server" "$SERVER_BIN" 0755 || die "Could not install $SERVER_BIN atomically."
  atomic_install "${build_dir}/shrinkray-server-doctor" "$DOCTOR_BIN" 0755 || die "Could not install $DOCTOR_BIN atomically."
  atomic_install "${TEMP_DIR}/server.conf" "$CONFIG_FILE" 0644 || die "Could not install $CONFIG_FILE atomically."
  atomic_install "${TEMP_DIR}/launcher" "$LAUNCHER_FILE" 0755 || die "Could not install $LAUNCHER_FILE atomically."
  atomic_install "${TEMP_DIR}/shrinkray.service" "$SERVICE_FILE" 0644 || die "Could not install $SERVICE_FILE atomically."
}

activate_and_verify() {
  local health_file="${TEMP_DIR}/health.json" label escaped
	run_systemctl daemon-reload
  if ! run_systemctl enable --now shrinkray; then
    print_service_diagnostics
    die "Could not enable and start shrinkray.service."
  fi
	if [ "$PREVIOUS_SERVICE_ACTIVE" = true ] && ! run_systemctl restart shrinkray; then
		print_service_diagnostics
		die "Could not restart the updated shrinkray.service."
	fi
  if ! run_systemctl is-active --quiet shrinkray; then
    print_service_diagnostics
    die "shrinkray.service is not active."
  fi
	if [ "$TEST_MODE" = true ]; then
		{
			printf '{"status":"ok","roots":['
			local separator=""
			for label in "${ROOT_LABELS[@]}"; do
				escaped="${label//\\/\\\\}"
				escaped="${escaped//\"/\\\"}"
				escaped="${escaped//&/\\u0026}"
				escaped="${escaped//</\\u003c}"
				escaped="${escaped//>/\\u003e}"
				printf '%s{"label":"%s"}' "$separator" "$escaped"
				separator=,
			done
			printf ']}\n'
		} > "$health_file"
		record_command curl --fail --silent --show-error "http://127.0.0.1:${PORT}/api/health"
	else
	for _ in $(seq 1 40); do
    if curl --fail --silent --show-error "http://127.0.0.1:${PORT}/api/health" --output "$health_file"; then
      break
    fi
    sleep 0.25
  done
	fi
  if [ ! -s "$health_file" ] || ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' "$health_file"; then
    print_service_diagnostics
    die "Local Shrinkray health check failed on 127.0.0.1:${PORT}."
  fi
  for label in "${ROOT_LABELS[@]}"; do
    escaped="${label//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
		escaped="${escaped//&/\\u0026}"
		escaped="${escaped//</\\u003c}"
		escaped="${escaped//>/\\u003e}"
    if ! grep -Fq "\"label\":\"${escaped}\"" "$health_file"; then
      print_service_diagnostics
      die "Health response did not include configured root label: $label"
    fi
  done
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
        TEST_SERVE_STATUS="${SHRINKRAY_INSTALL_TEST_TAILSCALE_SERVE_STATUS_AFTER_CONFIG:-https://test-host.example.ts.net:${TAILSCALE_HTTPS_PORT}/
|-- / proxy http://127.0.0.1:${PORT}}"
      fi
    fi
    return 0
  fi
  tailscale "$@"
}

run_ss() {
  record_command ss "$@"
  if [ "$TEST_MODE" = true ]; then
    printf '%s\n' "${SHRINKRAY_INSTALL_TEST_SS_OUTPUT:-}"
    return 0
  fi
  ss "$@"
}

ss_port_lines() {
  local status="$1" port="$2"
  printf '%s\n' "$status" | awk -v suffix=":${port}" '$4 ~ (suffix "$")'
}

serve_listener_exists() {
  local status="$1" wanted_port="$2"
  printf '%s\n' "$status" | awk -v wanted="$wanted_port" '
    function get_port(line, host) {
      host=line
      sub(/^[[:space:]]*https:\/\//, "", host)
      sub(/[[:space:]\/].*$/, "", host)
      if (host ~ /:[0-9]+$/) {
        sub(/^.*:/, "", host)
        return host
      }
      return 443
    }
    /^[[:space:]]*https:\/\// && get_port($0) == wanted { found=1 }
    END { exit(found ? 0 : 1) }
  '
}

serve_backend_at_port() {
  local status="$1" wanted_port="$2" backend="$3"
  printf '%s\n' "$status" | awk -v wanted="$wanted_port" -v backend="$backend" '
    function get_port(line, host) {
      host=line
      sub(/^[[:space:]]*https:\/\//, "", host)
      sub(/[[:space:]\/].*$/, "", host)
      if (host ~ /:[0-9]+$/) {
        sub(/^.*:/, "", host)
        return host
      }
      return 443
    }
    /^[[:space:]]*https:\/\// { port=get_port($0); next }
    port == wanted && index($0, backend) { found=1 }
    END { exit(found ? 0 : 1) }
  '
}

serve_port_is_only_backend() {
  local status="$1" wanted_port="$2" backend="$3"
  printf '%s\n' "$status" | awk -v wanted="$wanted_port" -v backend="$backend" '
    function get_port(line, host) {
      host=line
      sub(/^[[:space:]]*https:\/\//, "", host)
      sub(/[[:space:]\/].*$/, "", host)
      if (host ~ /:[0-9]+$/) {
        sub(/^.*:/, "", host)
        return host
      }
      return 443
    }
    /^[[:space:]]*https:\/\// { port=get_port($0); next }
    port == wanted && /^[[:space:]]*\|--/ {
      routes++
      if (index($0, backend)) matches++
    }
    END { exit(routes == 1 && matches == 1 ? 0 : 1) }
  '
}

print_port_conflict() {
  local port="$1" serve_status="$2" ss_status="$3"
  warn "Port $port is already occupied."
  ss_port_lines "$ss_status" "$port" >&2 || true
  if serve_listener_exists "$serve_status" "$port"; then
    warn "Tailscale Serve listener on port $port:"
    printf '%s\n' "$serve_status" >&2
  fi
}

check_backend_port_before_install() {
  local ss_status port_lines
  ss_status="$(run_ss -ltnp 2>/dev/null)" || die "Could not inspect listening TCP ports with ss."
  port_lines="$(ss_port_lines "$ss_status" "$PORT")"
  [ -z "$port_lines" ] && return 0
  if printf '%s\n' "$port_lines" | grep -Fq 'shrinkray-serve' && run_systemctl is-active --quiet shrinkray; then
    say "Backend port $PORT is owned by the existing shrinkray-server process."
    return 0
  fi
  warn "Backend port $PORT is already owned by another process:"
  printf '%s\n' "$port_lines" >&2
  die "Choose another backend with --port; Shrinkray did not replace the existing listener."
}

tailscale_is_installed() {
  if [ "$TEST_MODE" = true ]; then
    [ "${SHRINKRAY_INSTALL_TEST_TAILSCALE_INSTALLED:-1}" = 1 ]
    return
  fi
  command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1
}

install_tailscale_if_missing() {
  if tailscale_is_installed; then
    say "Tailscale client and daemon are installed."
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    say "Would install Tailscale from https://tailscale.com/install.sh."
    return
  fi
  if [ "$TEST_MODE" = true ]; then
    record_command curl -fsSL https://tailscale.com/install.sh '|' sh
    say "Test mode: recorded Tailscale installation."
    return
  fi
  say "Installing Tailscale using its official installer."
  curl -fsSL https://tailscale.com/install.sh | sh
  command -v tailscale >/dev/null 2>&1 || die "Tailscale installation did not provide the tailscale command."
  command -v tailscaled >/dev/null 2>&1 || die "Tailscale installation did not provide the tailscaled daemon."
}

tailscale_connected() {
  local json="$1"
  printf '%s' "$json" | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"'
}

tailscale_dns_name() {
  local json="$1" name
  name="$(printf '%s' "$json" | grep -Eom1 '"DNSName"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/^[^:]+:[[:space:]]*"([^"]+)"$/\1/')" || true
  name="${name%.}"
  if [[ "$name" =~ ^[A-Za-z0-9.-]+\.ts\.net$ ]]; then
    printf '%s' "$name"
  fi
}

inspect_tailscale_connection() {
  local status_text status_json dns_name
  status_text="$(run_tailscale status 2>&1)" || true
  [ -z "$status_text" ] || printf '%s\n' "$status_text"
  status_json="$(run_tailscale status --json 2>/dev/null)" || status_json=""
  if ! tailscale_connected "$status_json"; then
    if [ "$NON_INTERACTIVE" = true ]; then
      die "Tailscale is not connected. Connect it before using --non-interactive, or use --skip-tailscale."
    fi
    say "Tailscale login is required. The next command will display an authentication URL and wait for login."
    run_tailscale up || die "tailscale up did not complete successfully."
    status_text="$(run_tailscale status 2>&1)" || true
    [ -z "$status_text" ] || printf '%s\n' "$status_text"
    status_json="$(run_tailscale status --json 2>/dev/null)" || status_json=""
    tailscale_connected "$status_json" || die "Tailscale is still not connected after tailscale up."
  fi
  dns_name="$(tailscale_dns_name "$status_json")"
  if [ -n "$dns_name" ]; then
    if [ "$TAILSCALE_HTTPS_PORT" = 443 ]; then
      DETECTED_TAILSCALE_URL="https://${dns_name}/"
    else
      DETECTED_TAILSCALE_URL="https://${dns_name}:${TAILSCALE_HTTPS_PORT}/"
    fi
  else
    warn "Tailscale is connected, but its machine DNS name could not be read from status --json."
  fi
}

configure_tailscale_serve() {
  local backend="http://127.0.0.1:${PORT}" serve_status serve_json ss_status port_lines
  local configured_correct=false old_443_route=false
  if [ "$SKIP_TAILSCALE" = true ]; then
    say "Tailscale handling skipped as requested."
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    if ! tailscale_is_installed; then
      say "Would install Tailscale from https://tailscale.com/install.sh."
    fi
    say "Would enable and start tailscaled.service."
    say "Would inspect ports 443, $PORT, and $TAILSCALE_HTTPS_PORT with ss."
    say "Would inspect Tailscale Serve text and JSON status."
    say "Would preserve a matching route or configure HTTPS port $TAILSCALE_HTTPS_PORT for $backend when unoccupied."
    say "Would migrate a clearly owned Shrinkray HTTPS 443 listener only after the new route is verified."
    return
  fi
  install_tailscale_if_missing
  run_systemctl enable --now tailscaled || die "Could not enable and start tailscaled.service."
  inspect_tailscale_connection
  if ! serve_status="$(run_tailscale serve status 2>&1)"; then
    [ -z "$serve_status" ] || printf '%s\n' "$serve_status" >&2
    die "Could not inspect the current Tailscale Serve configuration."
  fi
  if ! serve_json="$(run_tailscale serve status --json 2>&1)"; then
    [ -z "$serve_json" ] || printf '%s\n' "$serve_json" >&2
    die "Could not inspect the JSON Tailscale Serve configuration."
  fi
  [ -n "$serve_json" ] || warn "Tailscale Serve JSON status was empty."
  ss_status="$(run_ss -ltnp 2>/dev/null)" || die "Could not inspect listening TCP ports with ss."
  say "Current Tailscale Serve status:"
  printf '%s\n' "$serve_status"

  port_lines="$(ss_port_lines "$ss_status" 443)"
  if [ -n "$port_lines" ] && printf '%s\n' "$port_lines" | grep -Fqi tailscaled; then
    warn "Tailscale currently owns TCP port 443. This can block Coolify, Traefik, Caddy, Nginx, Apache, or another host reverse proxy."
  fi

  if serve_backend_at_port "$serve_status" "$TAILSCALE_HTTPS_PORT" "$backend"; then
    configured_correct=true
    say "Tailscale Serve already proxies HTTPS port $TAILSCALE_HTTPS_PORT to $backend; leaving that listener unchanged."
  fi
  if serve_backend_at_port "$serve_status" 443 "$backend"; then
    old_443_route=true
    warn "Found an old Shrinkray Tailscale Serve listener on HTTPS port 443."
  elif serve_listener_exists "$serve_status" 443; then
    warn "An unrelated Tailscale Serve listener uses port 443; Shrinkray will leave it untouched."
  fi

  if serve_listener_exists "$serve_status" "$TAILSCALE_HTTPS_PORT" && [ "$configured_correct" = false ]; then
    print_port_conflict "$TAILSCALE_HTTPS_PORT" "$serve_status" "$ss_status"
    die "Choose another unused port with --tailscale-https-port; the existing Serve listener was not replaced."
  fi
  port_lines="$(ss_port_lines "$ss_status" "$TAILSCALE_HTTPS_PORT")"
  if [ -n "$port_lines" ]; then
    if [ "$configured_correct" = false ] || ! printf '%s\n' "$port_lines" | grep -Fqi tailscaled; then
      print_port_conflict "$TAILSCALE_HTTPS_PORT" "$serve_status" "$ss_status"
      die "Choose another unused port with --tailscale-https-port; Shrinkray did not replace the existing listener."
    fi
  fi

  if [ "$FORCE_TAILSCALE" = true ]; then
    warn "--force-tailscale never overrides an occupied listener; ownership checks remain enforced."
  fi

  if [ "$configured_correct" = false ]; then
    say "Configuring private Tailscale HTTPS port $TAILSCALE_HTTPS_PORT for $backend."
    run_tailscale serve --https="$TAILSCALE_HTTPS_PORT" --bg --yes "$backend" || die "Could not configure the Shrinkray Tailscale Serve listener."
    serve_status="$(run_tailscale serve status 2>&1)" || die "Could not verify Tailscale Serve after configuration."
    serve_json="$(run_tailscale serve status --json 2>&1)" || die "Could not verify JSON Tailscale Serve status after configuration."
    [ -n "$serve_json" ] || warn "Tailscale Serve JSON status was empty after configuration."
    serve_backend_at_port "$serve_status" "$TAILSCALE_HTTPS_PORT" "$backend" || die "The new HTTPS port $TAILSCALE_HTTPS_PORT route did not appear in Tailscale Serve status."
    say "Verified the new Shrinkray Tailscale Serve listener on HTTPS port $TAILSCALE_HTTPS_PORT."
  fi

  if [ "$old_443_route" = true ]; then
    if serve_port_is_only_backend "$serve_status" 443 "$backend"; then
      say "Removing only the old Shrinkray HTTPS port 443 listener after successful migration."
      run_tailscale serve --https=443 off || die "The new listener is working, but the old Shrinkray HTTPS port 443 listener could not be removed."
      serve_status="$(run_tailscale serve status 2>&1)" || die "Could not verify Tailscale Serve after removing the old port 443 listener."
      run_tailscale serve status --json >/dev/null || die "Could not verify JSON Tailscale Serve status after removing the old port 443 listener."
      if serve_backend_at_port "$serve_status" 443 "$backend"; then
        die "The old Shrinkray HTTPS port 443 listener is still present after the targeted removal."
      fi
      say "Migrated Shrinkray from Tailscale HTTPS port 443 to $TAILSCALE_HTTPS_PORT."
    else
      warn "The port 443 listener also contains unknown routes, so Shrinkray left it untouched. Remove only the old Shrinkray route manually after reviewing 'tailscale serve status'."
    fi
  else
    say "Port 443 was not claimed or changed by Shrinkray."
  fi
}

remote_health_check() {
  local browser_url="$1" remote_health
  [ -n "$browser_url" ] || return 0
  remote_health="${browser_url%/}/api/health"
  if [ "$TEST_MODE" = true ]; then
    record_command curl --fail --silent --show-error --max-time 10 "$remote_health"
    say "Test mode: recorded optional remote health check for $remote_health."
  elif curl --fail --silent --show-error --max-time 10 "$remote_health" >/dev/null; then
    say "Private HTTPS health check succeeded."
  else
    warn "Optional private HTTPS health check is not ready yet: $remote_health"
    warn "The authoritative loopback health check passed; HTTPS certificates or MagicDNS may still be completing."
  fi
}

print_success() {
  local browser_url="$DETECTED_TAILSCALE_URL"
  [ -z "$TAILSCALE_URL" ] || browser_url="$TAILSCALE_URL"
  printf '\nShrinkray is running.\n\n'
  printf 'Local backend:\nhttp://127.0.0.1:%s\n' "$PORT"
  if [ -n "$browser_url" ]; then
    printf '\nPrivate HTTPS dashboard:\n%s\n' "$browser_url"
  elif [ "$SKIP_TAILSCALE" = false ]; then
    printf '\nPrivate HTTPS dashboard:\nUnavailable (machine DNS name was not detected)\n'
  fi
  printf '\nCoolify/reverse-proxy HTTPS remains available on:\nport 443\n'
  printf '\nUseful commands:\n'
  printf 'systemctl status shrinkray\n'
  printf 'journalctl -u shrinkray -f\n'
  printf 'tailscale serve status\n'
  remote_health_check "$browser_url"
}

EXISTING_USER=""
EXISTING_GROUP=""
EXISTING_PORT=""
EXISTING_TAILSCALE_HTTPS_PORT=""
EXISTING_STATE_DIR=""
MANUAL_USER=""
MANUAL_GROUP=""
MANUAL_PORT=""
MANUAL_STATE_DIR=""

say "Shrinkray server installer"
detect_platform
create_temp_dir
load_managed_config
migrate_manual_service
select_service_user
select_preserved_settings
install_dependencies
validate_roots
check_backend_port_before_install
prepare_source
ensure_go
build_and_validate
write_config_candidate "${TEMP_DIR}/server.conf"
write_launcher_candidate "${TEMP_DIR}/launcher"
write_service_candidate "${TEMP_DIR}/shrinkray.service"

if [ "$DRY_RUN" = true ]; then
  configure_tailscale_serve
  say "Dry run complete; no system files or services were changed."
  say "Service user/group: ${SERVICE_USER}:${SERVICE_GROUP}"
  say "Loopback endpoint: http://127.0.0.1:${PORT}"
  say "Private Tailscale HTTPS port: ${TAILSCALE_HTTPS_PORT} (port 443 remains reserved)"
  say "Validated ${#ROOT_PATHS[@]} media root(s)."
  exit 0
fi

backup_managed_files
install_managed_files
activate_and_verify
configure_tailscale_serve
INSTALL_SUCCEEDED=true
FILES_REPLACED=false
rm -rf -- "$BACKUP_DIR"
BACKUP_DIR=""
print_success
