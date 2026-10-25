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

run_all() {
    run_panel
    run_wings
    if [[ -n "${APPLICATION_API_KEY:-}" ]]; then
        run_node
    else
        echo
        warn "APPLICATION_API_KEY not set - node connection skipped."
        warn "Create an Application API key in the panel (Admin -> Application API),"
        warn "put it in .env, then run: sudo ./install.sh node"
    fi
}

menu() {
    echo "${C_BOLD}Petro Panel installer${C_RESET}"
    echo "  1) Preflight checks"
    echo "  2) Install Panel"
    echo "  3) Install Wings (node daemon)"
    echo "  4) Install Panel + Wings + connect node (all-in-one)"
    echo "  5) Connect this node to an existing panel"
    echo "  q) Quit"
    read -r -p "Choose [1-5/q]: " choice
    case "$choice" in
        1) run_preflight ;;
        2) run_panel ;;
        3) run_wings ;;
        4) load_config; run_all ;;
        5) load_config; run_node ;;
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
        all)                load_config; run_all ;;
        -h|--help|help)     usage 0 ;;
        *)                  echo "Unknown command: $cmd" >&2; usage 1 ;;
    esac
}

main "$@"
