#!/usr/bin/env bash
# =============================================================================
# tests/unit.sh - offline unit tests for pure helper logic (no network/root).
# =============================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source scripts/lib.sh
# shellcheck disable=SC1091
source scripts/30-connect-node.sh
# shellcheck disable=SC1091
source scripts/10-install-panel.sh
# shellcheck disable=SC1091
source scripts/40-theme-arix.sh

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*" >&2; }

assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3: got '$1' want '$2'"; fi
}

echo "== Arix archive validation =="
arix_tmp=$(mktemp -d /tmp/arix-test.XXXXXX)
# 1. well-formed theme archive with a nested root (as real Arix zips ship)
( cd "$arix_tmp" && mkdir -p "Arix-1.3/pterodactyl/resources/scripts" "Arix-1.3/pterodactyl/app" \
    && touch "Arix-1.3/pterodactyl/artisan" "Arix-1.3/pterodactyl/resources/scripts/app.tsx" \
    && zip -qr good.zip "Arix-1.3" )
if verify_theme_zip "$arix_tmp/good.zip"; then ok "valid Arix-shaped zip accepted"; else bad "valid zip rejected"; fi
work=$(mktemp -d "$arix_tmp/extract.XXXXXX")
unzip -q "$arix_tmp/good.zip" -d "$work"
detected=$(detect_theme_root "$work")
if [[ "$detected" == "$work/Arix-1.3/pterodactyl" ]]; then
    ok "nested theme root detected"
else
    bad "theme root detection: $detected"
fi

# 2. archive missing the panel layout
( cd "$arix_tmp" && mkdir -p random && echo hi > random/readme.txt && zip -qr bad.zip random )
if verify_theme_zip "$arix_tmp/bad.zip"; then bad "non-theme zip should be rejected"; else ok "non-theme zip rejected"; fi

# 3. archive with path traversal entries
python3 - "$arix_tmp/evil.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../escape.txt", "x")
    z.writestr("artisan", "<?php")
    z.writestr("resources/scripts/x.tsx", "//x")
PY
if verify_theme_zip "$arix_tmp/evil.zip"; then bad "traversal zip should be rejected"; else ok "path-traversal zip rejected"; fi

# 4. missing archive configuration fails loudly (the licensing guard)
if ( unset ARIX_ZIP ARIX_SOURCE_URL; resolve_arix_archive >/dev/null 2>&1 ); then
    bad "resolver must refuse without an archive"
else
    ok "resolver refuses when no ARIX_ZIP/ARIX_SOURCE_URL is set"
fi
if ( ARIX_ZIP=/nonexistent/arix.zip; unset ARIX_SOURCE_URL; resolve_arix_archive >/dev/null 2>&1 ); then
    bad "missing ARIX_ZIP file must fail"
else
    ok "resolver rejects a missing ARIX_ZIP path"
fi
rm -rf "$arix_tmp" "$work"

echo "== load_config defaults =="
PETRO_CONFIG=/nonexistent/.env load_config
assert_eq "$PANEL_VERSION" "v1.11.10" "default panel version"
assert_eq "$WINGS_VERSION" "v1.13.4" "default wings version"
assert_eq "$NODE_DAEMON_PORT" "8080" "default daemon port"

echo "== gen_password =="
p1=$(gen_password); p2=$(gen_password)
if (( ${#p1} == 40 )); then ok "password length 40"; else bad "password length ${#p1}"; fi
if [[ "$p1" != "$p2" ]]; then ok "passwords are random"; else bad "passwords identical"; fi

echo "== expand_ports =="
expanded=$(expand_ports "25565,25570-25572" | tr '\n' ' ')
assert_eq "$expanded" "25565 25570 25571 25572 " "port list and range expansion"
if (expand_ports "25565,bad-port" >/dev/null 2>&1); then bad "invalid port rejected"; else ok "invalid port rejected"; fi
if (expand_ports "30000-29999" >/dev/null 2>&1); then bad "inverted range rejected"; else ok "inverted range rejected"; fi

echo "== build_location_payload =="
LOCATION_SHORT="loc1" LOCATION_LONG="Default"
loc_json=$(build_location_payload)
if echo "$loc_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d=={"short":"loc1","long":"Default"}, d'; then
    ok "location payload JSON"
else
    bad "location payload: $loc_json"
fi

echo "== build_node_payload =="
export NODE_NAME="node-1" NODE_FQDN="node.example.com" NODE_SCHEME="https" \
       NODE_BEHIND_PROXY="false" LOCATION_ID="7" NODE_MEMORY="8192" \
       NODE_MEMORY_OVERALLOCATE="0" NODE_DISK="20480" NODE_DISK_OVERALLOCATE="0" \
       NODE_UPLOAD_LIMIT="100" NODE_DAEMON_PORT="8080" NODE_SFTP_PORT="2022" \
       WINGS_DATA_PATH="/var/lib/pterodactyl/volumes"
node_json=$(build_node_payload)
if echo "$node_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["name"] == "node-1" and d["fqdn"] == "node.example.com"
assert d["location_id"] == 7 and isinstance(d["location_id"], int)
assert d["memory"] == 8192 and d["disk"] == 20480
assert d["daemon_listen"] == 8080 and d["daemon_sftp"] == 2022
assert d["behind_proxy"] is False and d["public"] is True
assert d["daemon_base"] == "/var/lib/pterodactyl/volumes"'; then
    ok "node payload JSON with correct types"
else
    bad "node payload: $node_json"
fi

echo "== build_allocation_payload =="
ALLOCATION_IP="203.0.113.10" ALLOCATION_PORTS="25565,25570-25572,27015"
alloc_json=$(build_allocation_payload)
if echo "$alloc_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ip"] == "203.0.113.10"
assert d["ports"] == ["25565","25570","25571","25572","27015"], d'; then
    ok "allocation payload expands ranges"
else
    bad "allocation payload: $alloc_json"
fi

echo "== panel_url (custom port support) =="
PANEL_FQDN="panel.example.com"
PANEL_SSL="false"; PANEL_PORT="80"
assert_eq "$(panel_url)" "http://panel.example.com" "standard HTTP URL hides port 80"
PANEL_PORT="8088"
assert_eq "$(panel_url)" "http://panel.example.com:8088" "custom HTTP port appears in URL"
PANEL_SSL="true"; PANEL_PORT="443"
assert_eq "$(panel_url)" "https://panel.example.com" "standard HTTPS URL hides port 443"
PANEL_SSL="true"; PANEL_PORT="8443"
assert_eq "$(panel_url)" "https://panel.example.com:8443" "custom HTTPS port appears in URL"

echo "== json_get =="
assert_eq "$(echo '{"attributes":{"id":42}}' | json_get 'd["attributes"]["id"]')" "42" \
    "json_get scalar extraction"

echo "== render-config.py (fallback config.yml writer) =="
tmp_cfg=$(mktemp /tmp/wings-config.XXXXXX.yml)
cat <<'JSON' | python3 scripts/render-config.py "$tmp_cfg" >/dev/null
{
  "debug": false,
  "uuid": "11111111-2222-4333-8444-555555555555",
  "token_id": "ptla-testid",
  "token": "secret-token-value",
  "api": {"host": "0.0.0.0", "port": 8080,
          "ssl": {"enabled": false, "cert": "/c/fullchain.pem", "key": "/c/privkey.pem"},
          "upload_limit": 100},
  "system": {"data": "/var/lib/pterodactyl/volumes", "sftp": {"bind_port": 2022}},
  "allowed_mounts": [],
  "remote": "https://panel.example.com"
}
JSON
if python3 -c 'import yaml' 2>/dev/null; then
    if python3 - "$tmp_cfg" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
assert d["uuid"] == "11111111-2222-4333-8444-555555555555"
assert d["token_id"] == "ptla-testid" and d["token"] == "secret-token-value"
assert d["api"]["port"] == 8080 and d["api"]["ssl"]["enabled"] is False
assert d["system"]["sftp"]["bind_port"] == 2022
assert d["remote"] == "https://panel.example.com" and d["allowed_mounts"] == []
PY
    then ok "render-config.py emits valid YAML matching the API response"
    else bad "render-config.py YAML mismatch"
    fi
else
    ok "render-config.py ran (PyYAML not installed, skipped parse check)"
fi
if [[ "$(stat -c %a "$tmp_cfg")" == "600" ]]; then
    ok "config.yml written with mode 600"
else
    bad "config.yml permissions"
fi
rm -f "$tmp_cfg"

echo "== preflight --json =="
if node scripts/preflight.mjs --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = {r["check"] for r in d["results"]}
assert "running as root" in names and "supported OS" in names and "port 80 free" in names'; then
    ok "preflight emits structured JSON"
else
    bad "preflight JSON invalid"
fi

echo
echo "Unit tests: ${pass} passed, ${fail} failed."
exit "$fail"
