#!/usr/bin/env bash
# =============================================================================
# scripts/lib.sh - shared helpers for the Petro Panel installer
# Source this file; do not execute it directly.
# =============================================================================

set -Eeuo pipefail

# ---- pretty logging ---------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log()  { echo "${C_GREEN}[petro]${C_RESET} $*"; }
info() { echo "${C_BLUE}[info]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[warn]${C_RESET} $*" >&2; }
die()  { echo "${C_RED}${C_BOLD}[error]${C_RESET} $*" >&2; exit 1; }

# ---- error trap -------------------------------------------------------------
on_error() {
    local exit_code=$? line=${1:-?}
    echo "${C_RED}${C_BOLD}[error]${C_RESET} command failed (exit ${exit_code}) at line ${line}." >&2
    echo "        Re-run the same command after fixing the issue; the installer is safe to re-run." >&2
    exit "$exit_code"
}
trap 'on_error ${LINENO}' ERR

# ---- configuration loading --------------------------------------------------
PETRO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_config() {
    local cfg="${PETRO_CONFIG:-${PETRO_ROOT}/.env}"
    if [[ -f "$cfg" ]]; then
        log "Loading configuration from ${cfg}"
        set -a
        # shellcheck disable=SC1090
        source "$cfg"
        set +a
    else
        warn "No .env file found at ${cfg} (cp .env.example .env). Using environment/default values."
    fi

    : "${PANEL_VERSION:=v1.11.10}"
    : "${WINGS_VERSION:=v1.13.4}"
    : "${PHP_VERSION:=8.3}"
    : "${PANEL_PATH:=/var/www/pterodactyl}"
    : "${PANEL_PORT:=80}"
    : "${WINGS_CONFIG_PATH:=/etc/pterodactyl}"
    : "${WINGS_DATA_PATH:=/var/lib/pterodactyl/volumes}"
    : "${DB_NAME:=panel}"
    : "${DB_USER:=pterodactyl}"
    : "${TIMEZONE:=UTC}"
    : "${PANEL_SSL:=false}"
    : "${NODE_SCHEME:=https}"
    : "${NODE_BEHIND_PROXY:=false}"
    : "${NODE_MEMORY:=8192}"
    : "${NODE_MEMORY_OVERALLOCATE:=0}"
    : "${NODE_DISK:=20480}"
    : "${NODE_DISK_OVERALLOCATE:=0}"
    : "${NODE_DAEMON_PORT:=8080}"
    : "${NODE_SFTP_PORT:=2022}"
    : "${NODE_UPLOAD_LIMIT:=100}"
    : "${LOCATION_SHORT:=loc1}"
    # Populated by the node step (Admin -> Application API key, starts with ptla_)
    : "${PANEL_URL:=}"
    : "${APPLICATION_API_KEY:=}"
}

require_vars() {
    local missing=()
    local v
    for v in "$@"; do
        if [[ -z "${!v:-}" ]]; then missing+=("$v"); fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing required configuration: ${missing[*]} (set it in .env or the environment)"
    fi
}

# ---- environment checks -----------------------------------------------------
require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "This command must be run as root (use sudo)."
    fi
}

detect_os() {
    [[ -r /etc/os-release ]] || die "Unsupported OS: /etc/os-release missing (need Debian 11/12 or Ubuntu 20.04+)."
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    case "$OS_ID" in
        debian) [[ "$OS_VERSION" =~ ^1[12]$ ]] || warn "Debian $OS_VERSION is untested; supported: 11 (bullseye), 12 (bookworm)." ;;
        ubuntu) [[ "$OS_VERSION" =~ ^(20.04|22.04|24.04)$ ]] || warn "Ubuntu $OS_VERSION is untested; supported: 20.04, 22.04, 24.04." ;;
        *) die "Unsupported distribution '$OS_ID'. Use Debian 11/12 or Ubuntu 20.04+." ;;
    esac
    log "Detected ${PRETTY_NAME:-$OS_ID $OS_VERSION} (${OS_CODENAME})"
}

apt_update() {
    export DEBIAN_FRONTEND=noninteractive
    log "Updating apt package indexes"
    apt-get update -y
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    log "Installing: $*"
    apt-get install -y --no-install-recommends "$@"
}

# ---- secrets ----------------------------------------------------------------
gen_password() {
    # URL/shell safe alphanumerics. Default 40 chars; pass a length if needed.
    # python3 avoids SIGPIPE (141) from `tr | head` under pipefail.
    local length=${1:-40}
    python3 -c 'import secrets,string,sys; n=int(sys.argv[1]); a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(n)))' "$length"
}

# Persist generated secrets so re-runs stay consistent.
persist_secret() {
    local key=$1 value=$2 file=/root/.petro-panel.env
    touch "$file"; chmod 600 "$file"
    if ! grep -q "^${key}=" "$file" 2>/dev/null; then
        echo "${key}=\"${value}\"" >> "$file"
    fi
}

read_secret() {
    local key=$1 file=/root/.petro-panel.env
    [[ -r "$file" ]] || return 1
    # shellcheck disable=SC1090
    source "$file"
    printf '%s' "${!key:-}"
}

# ---- Pterodactyl Application API helper ------------------------------------
# usage: api_call METHOD PATH [JSON_BODY]
# Requires PANEL_URL and APPLICATION_API_KEY.
api_call() {
    local method=$1 path=$2 body=${3:-}
    require_vars PANEL_URL APPLICATION_API_KEY
    local args=(-sS -X "$method"
        -H "Accept: application/json"
        -H "Content-Type: application/json"
        -H "Authorization: Bearer ${APPLICATION_API_KEY}"
        -w '\n%{http_code}')
    [[ -n "$body" ]] && args+=(-d "$body")
    local response
    response=$(curl "${args[@]}" "${PANEL_URL%/}/api/application${path}")
    local http_code body_text
    http_code=$(printf '%s' "$response" | tail -n1)
    body_text=$(printf '%s' "$response" | sed '$d')
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo "$body_text" >&2
        die "API call ${method} ${path} failed with HTTP ${http_code}"
    fi
    printf '%s' "$body_text"
}

# ---- Application API JSON payload builders ---------------------------------
build_location_payload() {
    require_vars LOCATION_SHORT
    LOCATION_SHORT="$LOCATION_SHORT" LOCATION_LONG="${LOCATION_LONG:-}" \
    python3 -c 'import json,os; print(json.dumps({"short": os.environ["LOCATION_SHORT"], "long": os.environ.get("LOCATION_LONG","")}))'
}

build_node_payload() {
    require_vars NODE_NAME NODE_FQDN NODE_SCHEME NODE_BEHIND_PROXY LOCATION_ID \
                 NODE_MEMORY NODE_MEMORY_OVERALLOCATE NODE_DISK NODE_DISK_OVERALLOCATE \
                 NODE_UPLOAD_LIMIT NODE_DAEMON_PORT NODE_SFTP_PORT WINGS_DATA_PATH
    NODE_NAME="$NODE_NAME" NODE_FQDN="$NODE_FQDN" NODE_SCHEME="$NODE_SCHEME" \
    NODE_BEHIND_PROXY="$NODE_BEHIND_PROXY" LOCATION_ID="$LOCATION_ID" \
    NODE_MEMORY="$NODE_MEMORY" NODE_MEMORY_OVERALLOCATE="$NODE_MEMORY_OVERALLOCATE" \
    NODE_DISK="$NODE_DISK" NODE_DISK_OVERALLOCATE="$NODE_DISK_OVERALLOCATE" \
    NODE_UPLOAD_LIMIT="$NODE_UPLOAD_LIMIT" NODE_DAEMON_PORT="$NODE_DAEMON_PORT" \
    NODE_SFTP_PORT="$NODE_SFTP_PORT" WINGS_DATA_PATH="$WINGS_DATA_PATH" \
    python3 -c '
import json, os
e = os.environ
print(json.dumps({
    "public": True,
    "name": e["NODE_NAME"],
    "location_id": int(e["LOCATION_ID"]),
    "fqdn": e["NODE_FQDN"],
    "scheme": e["NODE_SCHEME"],
    "behind_proxy": e["NODE_BEHIND_PROXY"].lower() == "true",
    "maintenance_mode": False,
    "memory": int(e["NODE_MEMORY"]),
    "memory_overallocate": int(e["NODE_MEMORY_OVERALLOCATE"]),
    "disk": int(e["NODE_DISK"]),
    "disk_overallocate": int(e["NODE_DISK_OVERALLOCATE"]),
    "upload_size": int(e["NODE_UPLOAD_LIMIT"]),
    "daemon_listen": int(e["NODE_DAEMON_PORT"]),
    "daemon_sftp": int(e["NODE_SFTP_PORT"]),
    "daemon_base": e["WINGS_DATA_PATH"],
}))'
}

build_allocation_payload() {
    require_vars ALLOCATION_IP ALLOCATION_PORTS
    ALLOCATION_IP="$ALLOCATION_IP" ALLOCATION_ALIAS="${ALLOCATION_ALIAS:-}" \
    ALLOCATION_PORTS="$ALLOCATION_PORTS" python3 -c '
import json, os
ports = []
for part in os.environ["ALLOCATION_PORTS"].split(","):
    part = part.strip()
    if "-" in part:
        lo, hi = part.split("-", 1)
        ports.extend(str(p) for p in range(int(lo), int(hi) + 1))
    elif part:
        ports.append(part)
payload = {"ip": os.environ["ALLOCATION_IP"], "ports": ports}
if os.environ.get("ALLOCATION_ALIAS"):
    payload["alias"] = os.environ["ALLOCATION_ALIAS"]
print(json.dumps(payload))'
}

wait_for_panel() {
    require_vars PANEL_URL
    log "Waiting for panel at ${PANEL_URL}"
    for _ in $(seq 1 30); do
        if curl -fsS -o /dev/null --max-time 5 "${PANEL_URL%/}/api/system" 2>/dev/null \
           || curl -fsS -o /dev/null --max-time 5 "${PANEL_URL%/}/" 2>/dev/null; then
            log "Panel is responding."
            return 0
        fi
        sleep 2
    done
    die "Panel did not become reachable at ${PANEL_URL} within 60 seconds."
}

# ---- systemd convenience ----------------------------------------------------
service_enable() { systemctl enable "$1" >/dev/null; }
service_restart() { systemctl restart "$1"; }
