#!/usr/bin/env bash
# =============================================================================
# install.sh - Petro Panel (Pterodactyl + Wings) installer entrypoint
#
# Usage:
#   sudo ./install.sh                 # interactive menu
#   sudo ./install.sh preflight       # check this machine is ready
#   sudo ./install.sh panel           # install the panel only
#   sudo ./install.sh wings           # install Docker + Wings (a node) only
#   sudo ./install.sh node            # register/connect this node to the panel
#   sudo ./install.sh all             # panel + wings + connect (same machine)
#   sudo ./install.sh apikey          # create/print a ptla_ Application API key
#   sudo ./install.sh theme           # install Arix theme from ARIX_ZIP/URL
#   sudo ./install.sh theme --uninstall  # restore the pre-theme backup
#
# Configuration is read from .env (see .env.example) or real env vars.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

run_preflight() {
    # Preflight is a reporting tool: a non-zero result must not trip set -e.
    node "${SCRIPT_DIR}/scripts/preflight.mjs" "$@" || true
}

run_panel() {
    bash "${SCRIPT_DIR}/scripts/10-install-panel.sh"
}

run_wings() {
    bash "${SCRIPT_DIR}/scripts/20-install-wings.sh"
}

run_node() {
    bash "${SCRIPT_DIR}/scripts/30-connect-node.sh"
}

run_theme() {
    bash "${SCRIPT_DIR}/scripts/40-theme-arix.sh" "$@"
}

run_apikey() {
    bash "${SCRIPT_DIR}/scripts/35-create-api-key.sh" "$@"
}

run_all() {
    run_panel
    run_wings

    # Same-machine defaults so the node can connect without extra editing.
    export NODE_FQDN="${NODE_FQDN:-$PANEL_FQDN}"
    export ALLOCATION_IP="${ALLOCATION_IP:-$NODE_FQDN}"
    export NODE_SCHEME="${NODE_SCHEME:-$([[ "${PANEL_SSL:-false}" == "true" ]] && echo https || echo http)}"
    export PANEL_URL="${PANEL_URL:-$(panel_url)}"

    if [[ -z "${APPLICATION_API_KEY:-}" ]]; then
        log "No APPLICATION_API_KEY set - creating one on the installed panel"
        export APPLICATION_API_KEY
        APPLICATION_API_KEY=$(run_apikey | awk '/^ptla_/{print; exit}')
        [[ "$APPLICATION_API_KEY" == ptla_* ]] || die "could not obtain an Application API key from the panel"
    fi
    run_node
}

menu() {
    echo "${C_BOLD}Petro Panel installer${C_RESET}"
    echo "  1) Preflight checks"
    echo "  2) Install Panel"
    echo "  3) Install Wings (node daemon)"
    echo "  4) Install Panel + Wings + connect node (all-in-one)"
    echo "  5) Connect this node to an existing panel"
    echo "  6) Install Arix theme (needs a licensed ARIX_ZIP/ARIX_SOURCE_URL)"
    echo "  q) Quit"
    read -r -p "Choose [1-6/q]: " choice
    case "$choice" in
        1) run_preflight ;;
        2) run_panel ;;
        3) run_wings ;;
        4) load_config; run_all ;;
        5) load_config; run_node ;;
        6) load_config; run_theme ;;
        q|Q) exit 0 ;;
        *) die "Invalid choice." ;;
    esac
}

main() {
    local cmd=${1:-}
    case "$cmd" in
        ""|menu)            load_config; menu ;;
        preflight)          shift; run_preflight "$@" ;;
        panel)              load_config; run_panel ;;
        wings)              load_config; run_wings ;;
        node|connect-node)  load_config; run_node ;;
        apikey|api-key)     shift; load_config; run_apikey "$@" ;;
        theme|arix)         shift; load_config; run_theme "$@" ;;
        all)                load_config; run_all ;;
        -h|--help|help)     usage 0 ;;
        *)                  echo "Unknown command: $cmd" >&2; usage 1 ;;
    esac
}

main "$@"
