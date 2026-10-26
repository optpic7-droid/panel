#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-down.sh
# Stop the Codespace Pterodactyl stack. Data in .codespace/data is kept unless
# --purge is passed (which also removes the database and all servers).
#
# Usage:
#   bash scripts/codespace-down.sh            # stop containers, keep data
#   bash scripts/codespace-down.sh --logs     # show recent logs, then stop
#   bash scripts/codespace-down.sh --purge    # stop + delete all local data
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/codespace-common.sh"

main() {
    require_codespace
    [[ -f "$CODESPACE_ENV" ]] || die "No Codespace stack found (${CODESPACE_ENV} missing)."

    if [[ "${1:-}" == "--logs" ]]; then
        compose logs --tail 80 || true
    fi

    log "Stopping Pterodactyl containers"
    compose down

    if [[ "${1:-}" == "--purge" ]]; then
        log "Purging all panel/node data under ${CODESPACE_DIR}/data"
        rm -rf "${CODESPACE_DIR}/data"
        rm -f "$CODESPACE_ENV"
        warn "All database contents, servers and credentials were deleted."
    else
        log "Data preserved in ${CODESPACE_DIR}/data - re-run codespace-up.sh to resume."
    fi
}

main "$@"
