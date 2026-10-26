#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-common.sh - shared helpers for the Codespaces stack.
# Sourced by codespace-up.sh / codespace-down.sh; safe to source in tests.
# =============================================================================

CODESPACE_DIR="${CODESPACE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.codespace}"
CODESPACE_ENV="${CODESPACE_DIR}/.env"
COMPOSE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/codespace/docker-compose.yml"

require_codespace() {
    if [[ -z "${CODESPACE_NAME:-}" || -z "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
        cat >&2 <<'EOF'
[error] This command must run inside a GitHub Codespace (CODESPACE_NAME is unset).
        Open the repo in Codespaces: Code -> Codespaces -> Create codespace,
        then run: bash scripts/codespace-up.sh
EOF
        exit 1
    fi
}

# Public browser URL of a forwarded Codespace port.
codespace_url() {
    local port=$1
    echo "https://${CODESPACE_NAME}-${port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
}

# Pick a v1 panel image tag when GHCR publishes one, otherwise :latest.
# Keeps the stack on Pterodactyl 1.x even if the package moves to v2.
resolve_panel_image() {
    local pinned="ghcr.io/pterodactyl/panel:v1.11.10"
    if docker manifest inspect "$pinned" >/dev/null 2>&1; then
        echo "$pinned"
    else
        echo "ghcr.io/pterodactyl/panel:latest"
    fi
}

compose() {
    docker compose --env-file "$CODESPACE_ENV" -f "$COMPOSE_FILE" "$@"
}

# Read one KEY=VALUE from the codespace env file.
codespace_env_get() {
    local key=$1
    [[ -f "$CODESPACE_ENV" ]] || return 1
    sed -n "s/^${key}=//p" "$CODESPACE_ENV" | head -1
}
