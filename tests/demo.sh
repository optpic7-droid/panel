#!/usr/bin/env bash
# =============================================================================
# tests/demo.sh - boots demo/server.mjs on a random port and exercises the
# emulated Application API contract (the same one 30-connect-node.sh uses).
# =============================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*" >&2; }
expect_code() { # desc expected actual
    if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1: got $3 want $2"; fi
}

rm -f demo/data.json
node demo/server.mjs > /tmp/petro-demo.log 2>&1 &
demo_pid=$!
trap 'kill "$demo_pid" 2>/dev/null || true' EXIT

port=""
for _ in $(seq 1 50); do
    port=$(sed -n 's/^PETRO_DEMO_PORT=//p' /tmp/petro-demo.log | head -1)
    [[ -n "$port" ]] && break
    sleep 0.1
done
if [[ -z "$port" ]]; then
    echo "demo server failed to start"; cat /tmp/petro-demo.log; exit 1
fi
base="http://127.0.0.1:${port}"
echo "demo server on ${base}"

api_key=$(sed -n 's/^Application API key: //p' /tmp/petro-demo.log | head -1)
auth=(-H "Authorization: Bearer ${api_key}" -H "Content-Type: application/json" -H "Accept: application/json")

# health
code=$(curl -s -o /dev/null -w '%{http_code}' "$base/api/system")
expect_code "GET /api/system" 200 "$code"

# auth rejection
code=$(curl -s -o /dev/null -w '%{http_code}' "$base/api/application/nodes")
expect_code "missing bearer token rejected" 401 "$code"

# location + node + allocations, exactly like 30-connect-node.sh
loc=$(curl -s "${auth[@]}" -X POST "$base/api/application/locations" \
    -d '{"short":"loc1","long":"Default location"}')
loc_id=$(echo "$loc" | python3 -c 'import json,sys; print(json.load(sys.stdin)["attributes"]["id"])')
expect_code "POST /locations" 1 "$loc_id"

node=$(curl -s "${auth[@]}" -X POST "$base/api/application/nodes" -d '{
  "public": true, "name": "node-1", "location_id": 1, "fqdn": "node.local",
  "scheme": "http", "behind_proxy": false, "maintenance_mode": false,
  "memory": 8192, "memory_overallocate": 0, "disk": 20480, "disk_overallocate": 0,
  "upload_size": 100, "daemon_listen": 8080, "daemon_sftp": 2022,
  "daemon_base": "/var/lib/pterodactyl/volumes"}')
node_id=$(echo "$node" | python3 -c 'import json,sys; print(json.load(sys.stdin)["attributes"]["id"])')
expect_code "POST /nodes" 1 "$node_id"

code=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" \
    -X POST "$base/api/application/nodes/1/allocations" \
    -d '{"ip":"127.0.0.1","ports":["25565","25570","25571","25572"]}')
expect_code "POST /nodes/1/allocations" 204 "$code"

cfg=$(curl -s "${auth[@]}" "$base/api/application/nodes/1/configuration")
if printf '%s' "$cfg" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["api"]["port"] == 8080 and d["system"]["sftp"]["bind_port"] == 2022
assert d["token_id"].startswith("ptla_") and d["remote"].startswith("http://")
'; then
    ok "GET /nodes/1/configuration matches Node::getConfiguration() shape"
else
    bad "configuration shape: $cfg"
fi

# dashboard session
code=$(curl -s -o /dev/null -w '%{http_code}' -c /tmp/petro-demo.cookies \
    -X POST "$base/api/demo/login" -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"petro-demo"}')
expect_code "dashboard login" 200 "$code"
state=$(curl -s -b /tmp/petro-demo.cookies "$base/api/demo/state")
if printf '%s' "$state" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["counts"]["nodes"] == 1 and d["counts"]["allocations"] == 4
assert d["nodes"][0]["configured"] is True
'; then
    ok "dashboard state reflects the connected node"
else
    bad "dashboard state: $state"
fi
rm -f /tmp/petro-demo.cookies

# static UI
html=$(curl -s "$base/")
if grep -q "Petro Panel" <<<"$html"; then ok "dashboard HTML served"; else bad "index.html"; fi

echo
echo "Demo tests: ${pass} passed, ${fail} failed."
exit "$fail"
