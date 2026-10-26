#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-common.sh - shared helpers for the Codespaces stack.
# Sourced by codespace-up.sh / codespace-down.sh; safe to source in tests.
# =============================================================================

CODESPACE_DIR="${CODESPACE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.codespace}"
CODESPACE_ENV="${CODESPACE_DIR}/.env"
COMPOSE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/codespace/docker-compose.yml"

# /proc/1/environ is read by the recovery test with a temp file override.
PROC_ENVIRON="${PROC_ENVIRON:-/proc/1/environ}"

require_codespace() {
    # 'sudo su' / 'sudo -i' reset the environment and drop the Codespace
    # variables. PID 1 keeps the original environment and is readable by
    # root, so recover from there before giving up.
    if [[ -z "${CODESPACE_NAME:-}" && -r "$PROC_ENVIRON" ]]; then
        local recovered
        recovered=$(tr '\0' '\n' < "$PROC_ENVIRON" | sed -n 's/^CODESPACE_NAME=//p')
        [[ -n "$recovered" ]] && export CODESPACE_NAME="$recovered"
        recovered=$(tr '\0' '\n' < "$PROC_ENVIRON" | sed -n 's/^GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN=//p')
        [[ -n "$recovered" ]] && export GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN="$recovered"
    fi
    : "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:=app.github.dev}"

    # Last resort: ask gh for one of the account's codespaces.
    if [[ -z "${CODESPACE_NAME:-}" ]] && command -v gh >/dev/null 2>&1; then
        local picked
        picked=$(gh codespace list --json name -q '.[0].name' 2>/dev/null || true)
        [[ -n "$picked" ]] && export CODESPACE_NAME="$picked"
    fi

    if [[ -z "${CODESPACE_NAME:-}" ]]; then
        cat >&2 <<'EOF'
[error] CODESPACE_NAME is unset and could not be recovered.
        Easiest fix: type `exit` to leave the root shell (sudo su strips
        Codespace variables) and run `bash scripts/codespace-up.sh` as the
        normal Codespace user. Docker does not need sudo in Codespaces.
        Manual alternative:
          export CODESPACE_NAME=<name>     # see: gh codespace list
          export GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN=app.github.dev
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
# Keeps the stack on Pterodactyl 1.x even if the package moves to v2,
# because the v1 and v2 images use different env vars/entrypoints.
resolve_panel_image() {
    local tag
    for tag in v1.11.10 v1.11.9 v1.11.8 v1.11.7; do
        if docker manifest inspect "ghcr.io/pterodactyl/panel:${tag}" >/dev/null 2>&1; then
            echo "ghcr.io/pterodactyl/panel:${tag}"
            return 0
        fi
    done
    echo "ghcr.io/pterodactyl/panel:latest"
}

# Official Blueprint framework image (BlueprintFramework/framework-docker).
# It is built FROM the matching ghcr.io/pterodactyl/panel tag with the
# extension framework, node/yarn and the /blueprint_extensions auto-sync
# baked in - a drop-in replacement that keeps the stock entrypoint.
# Tags mirror panel versions; prefer a 1.11.x image, then known current
# framework builds, then :latest.
resolve_blueprint_image() {
    local tag
    for tag in v1.11.10 v1.11.9 v1.11.8 v1.11.7 \
               v1.15.2 v1.15.1 v1.15.0 v1.14.1 v1.14.0; do
        if docker manifest inspect "ghcr.io/blueprintframework/blueprint:${tag}" >/dev/null 2>&1; then
            echo "ghcr.io/blueprintframework/blueprint:${tag}"
            return 0
        fi
    done
    echo "ghcr.io/blueprintframework/blueprint:latest"
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
