#!/usr/bin/env bash
# =============================================================================
# scripts/30-connect-node.sh
# Registers THIS machine as a node on the panel over the Application API and
# writes the Wings configuration, then starts Wings. Creates the location and
# node automatically and adds the requested allocations.
#
# Required config (.env): PANEL_URL, APPLICATION_API_KEY (ptla_...),
# NODE_FQDN, NODE_NAME, LOCATION_SHORT, ALLOCATION_IP, ALLOCATION_PORTS.
# Run on the node machine AFTER scripts/20-install-wings.sh (works remotely
# too - it can also just write config.yml for an existing Wings install).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# Expand "25565,25570-25572" into "25565 25570 25571 25572".
expand_ports() {
    local spec=$1 part lo hi
    for part in ${spec//,/ }; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
            (( lo <= hi )) || die "Bad port range: $part"
            for ((p=lo; p<=hi; p++)); do echo "$p"; done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            echo "$part"
        else
            die "Invalid port specification: $part"
        fi
    done
}

# Extract one scalar from an API JSON response without needing jq.
json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"__builtins__":{}}, {"d":d}))' "$1"; }

check_api() {
    log "Verifying panel API access at ${PANEL_URL}"
    api_call GET /nodes >/dev/null
}

ensure_location() {
    local existing
    existing=$(api_call GET "/locations?per_page=100")
    LOCATION_ID=$(printf '%s' "$existing" | python3 -c '
import json, os, sys
d = json.load(sys.stdin)
want = os.environ["LOCATION_SHORT"]
for item in d.get("data", []):
    a = item.get("attributes", {})
    if a.get("short") == want:
        print(a.get("id")); break
')
    if [[ -n "${LOCATION_ID:-}" ]]; then
        log "Reusing location '${LOCATION_SHORT}' (id ${LOCATION_ID})"
        return
    fi

    log "Creating location '${LOCATION_SHORT}'"
    local payload resp
    payload=$(build_location_payload)
    resp=$(api_call POST /locations "$payload")
    LOCATION_ID=$(printf '%s' "$resp" | json_get 'd["attributes"]["id"]')
}

ensure_node() {
    local existing
    existing=$(api_call GET "/nodes?per_page=100")
    NODE_ID=$(printf '%s' "$existing" | python3 -c '
import json, os, sys
d = json.load(sys.stdin)
want = os.environ["NODE_NAME"]
for item in d.get("data", []):
    a = item.get("attributes", {})
    if a.get("name") == want:
        print(a.get("id")); break
')
    if [[ -n "${NODE_ID:-}" ]]; then
        log "Reusing node '${NODE_NAME}' (id ${NODE_ID})"
        return
    fi

    log "Creating node '${NODE_NAME}' (${NODE_FQDN})"
    local payload resp
    payload=$(build_node_payload)
    resp=$(api_call POST /nodes "$payload")
    NODE_ID=$(printf '%s' "$resp" | json_get 'd["attributes"]["id"]')
    log "Node created with id ${NODE_ID}"
}

add_allocations() {
    log "Adding allocations on ${ALLOCATION_IP}: ${ALLOCATION_PORTS}"
    # Fail early on a malformed port specification before calling the API.
    expand_ports "$ALLOCATION_PORTS" >/dev/null
    local payload
    payload=$(build_allocation_payload)
    api_call POST "/nodes/${NODE_ID}/allocations" "$payload" >/dev/null
}

write_wings_config() {
    mkdir -p "$WINGS_CONFIG_PATH"
    if [[ -x /usr/local/bin/wings ]]; then
        log "Running 'wings configure' for node ${NODE_ID}"
        /usr/local/bin/wings configure \
            --panel-url "$PANEL_URL" \
            --token "$APPLICATION_API_KEY" \
            --node "$NODE_ID" \
            --config-path "${WINGS_CONFIG_PATH}/config.yml" \
            --override
    else
        warn "wings binary not found on this machine; writing ${WINGS_CONFIG_PATH}/config.yml from the API instead."
        api_call GET "/nodes/${NODE_ID}/configuration" \
            | python3 "${SCRIPT_DIR}/render-config.py" "${WINGS_CONFIG_PATH}/config.yml"
    fi
}

restart_wings() {
    if ! systemctl list-unit-files wings.service >/dev/null 2>&1; then
        warn "wings.service not installed - run scripts/20-install-wings.sh on this node first."
        return
    fi
    log "Starting Wings"
    systemctl daemon-reload
    systemctl enable --now wings
    sleep 5
    systemctl --no-pager --full status wings | head -12 || true
}

show_summary() {
    local node
    node=$(api_call GET "/nodes/${NODE_ID}")
    echo
    log "Node connected. Panel record:"
    printf '%s' "$node" | python3 -m json.tool | grep -E '"(id|name|fqdn|scheme|daemon_listen|daemon_sftp|memory|disk)"' || true
    echo
    log "Heartbeats appear within ~10s. Verify in the panel: Admin -> Nodes -> ${NODE_NAME}"
    log "Open these ports on the node firewall: 8080 (Wings API), 2022 (SFTP) + your allocation ports."
}

main() {
    load_config
    require_root
    require_vars PANEL_URL APPLICATION_API_KEY NODE_FQDN NODE_NAME LOCATION_SHORT ALLOCATION_IP ALLOCATION_PORTS
    check_api
    ensure_location
    ensure_node
    add_allocations
    write_wings_config
    restart_wings
    show_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
