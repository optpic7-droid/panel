#!/usr/bin/env bash
# =============================================================================
# tests/integration.sh - end-to-end test of the node-connection flow against
# tests/mock-panel.mjs (no real panel, Docker, root or network needed).
# =============================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*" >&2; }

# ---- start mock panel -------------------------------------------------------
mock_pid=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    if [[ -n "$mock_pid" ]]; then kill "$mock_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

# The mock prints its chosen ephemeral port as the first stdout line.
node tests/mock-panel.mjs > /tmp/mock-panel.port 2>/dev/null &
mock_pid=$!
for _ in $(seq 1 50); do
    [[ -s /tmp/mock-panel.port ]] && break
    sleep 0.1
done
port=$(tr -d '[:space:]' < /tmp/mock-panel.port)
[[ -n "$port" ]] || { echo "mock panel failed to start"; exit 1; }
echo "mock panel listening on 127.0.0.1:${port}"

# ---- load the real installer code ------------------------------------------
# shellcheck disable=SC1091
source scripts/lib.sh
# shellcheck disable=SC1091
source scripts/30-connect-node.sh

export PANEL_URL="http://127.0.0.1:${port}"
export APPLICATION_API_KEY="ptla_test"
export LOCATION_SHORT="loc1" LOCATION_LONG="Default location"
export NODE_NAME="node-1" NODE_FQDN="node.example.com" NODE_SCHEME="http"
export NODE_BEHIND_PROXY="false"
export NODE_MEMORY="8192" NODE_MEMORY_OVERALLOCATE="0"
export NODE_DISK="20480" NODE_DISK_OVERALLOCATE="0"
export NODE_UPLOAD_LIMIT="100" NODE_DAEMON_PORT="8080" NODE_SFTP_PORT="2022"
export ALLOCATION_IP="203.0.113.10" ALLOCATION_PORTS="25565,25570-25572"
export WINGS_DATA_PATH="/var/lib/pterodactyl/volumes"
WINGS_CONFIG_PATH=$(mktemp -d /tmp/ptero-wings.XXXXXX)
export WINGS_CONFIG_PATH

echo "== happy path =="
if check_api; then ok "API authentication accepted"; else bad "API authentication failed"; fi
ensure_location
if [[ "${LOCATION_ID:-}" == "1" ]]; then ok "location created (id 1)"; else bad "location id: ${LOCATION_ID:-none}"; fi
ensure_node
if [[ "${NODE_ID:-}" == "1" ]]; then ok "node created (id 1)"; else bad "node id: ${NODE_ID:-none}"; fi
if add_allocations; then ok "allocations accepted (port range expanded)"; else bad "allocations failed"; fi
write_wings_config
if [[ -f "${WINGS_CONFIG_PATH}/config.yml" ]]; then
    ok "config.yml generated from API response"
    if grep -q "uuid: " "${WINGS_CONFIG_PATH}/config.yml"; then ok "config.yml contains uuid"; else bad "config.yml missing uuid"; fi
    if grep -q "remote: \"${PANEL_URL}\"" "${WINGS_CONFIG_PATH}/config.yml"; then
        ok "config.yml points at panel"
    else
        bad "config.yml remote mismatch"
    fi
    if [[ "$(stat -c %a "${WINGS_CONFIG_PATH}/config.yml")" == "600" ]]; then
        ok "config.yml is mode 600"
    else
        bad "config.yml permissions"
    fi
else
    bad "config.yml missing"
fi
restart_wings || true   # systemd is absent in sandboxes; warning is expected

echo "== idempotent re-run reuses location and node =="
ensure_location
ensure_node
if [[ "$LOCATION_ID" == "1" && "$NODE_ID" == "1" ]]; then
    ok "existing location/node reused"
else
    bad "duplicate resources created"
fi

echo "== bad token is rejected =="
if (APPLICATION_API_KEY="ptla_wrong" api_call GET /nodes >/dev/null 2>&1); then
    bad "invalid token should fail"
else
    ok "invalid token rejected with non-zero exit"
fi

rm -rf "$WINGS_CONFIG_PATH" /tmp/mock-panel.port
echo
echo "Integration tests: ${pass} passed, ${fail} failed."
exit "$fail"
