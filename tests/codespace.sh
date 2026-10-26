#!/usr/bin/env bash
# =============================================================================
# tests/codespace.sh - offline validation of the Codespaces stack (Docker is
# not available in CI/sandboxes, so we validate structure and pure helpers).
# =============================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*" >&2; }

# shellcheck disable=SC1091
source scripts/codespace-common.sh

echo "== compose file =="
if python3 - <<'PY'
import yaml, sys
with open("deploy/codespace/docker-compose.yml") as f:
    c = yaml.safe_load(f)
svc = c["services"]
for name in ("database", "cache", "panel", "wings"):
    assert name in svc, f"missing service {name}"
assert "mariadb" in svc["database"]["image"]
assert "pterodactyl/panel" in svc["panel"]["image"] or "${PANEL_IMAGE}" in svc["panel"]["image"]
assert "pterodactyl/wings" in svc["wings"]["image"]
assert svc["wings"].get("privileged") is True
assert any("/var/run/docker.sock" in v for v in svc["wings"]["volumes"])
assert "8080:80" in svc["panel"]["ports"]
assert "8081:8080" in svc["wings"]["ports"]
# all host bind paths stay inside PTERO_DATA_DIR (no writes outside the repo)
for s in svc.values():
    for v in s.get("volumes", []):
        host = v.split(":")[0]
        assert host.startswith("${PTERO_DATA_DIR}") or host.startswith("/var/run") or host.startswith("/var/lib/docker") or host.startswith("/etc/ssl"), host
print("compose structure valid")
PY
then ok "compose services, images, ports and volumes"; else bad "compose validation"; fi

echo "== devcontainer =="
if python3 - <<'PY'
import json
d = json.load(open(".devcontainer/devcontainer.json"))
assert 8080 in d["forwardPorts"] and 8081 in d["forwardPorts"] and 2022 in d["forwardPorts"]
assert d["portsAttributes"]["8080"]["visibility"] == "public"
print("devcontainer json valid")
PY
then ok "devcontainer forwards the right ports publicly"; else bad "devcontainer"; fi

echo "== helper functions =="
CODESPACE_NAME="crispy-space-abc123"
GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN="app.github.dev"
if [[ "$(codespace_url 8080)" == "https://crispy-space-abc123-8080.app.github.dev" ]]; then
    ok "codespace_url builds the forwarded URL"
else
    bad "codespace_url: $(codespace_url 8080)"
fi
if [[ "$COMPOSE_FILE" == "$ROOT/deploy/codespace/docker-compose.yml" && -f "$COMPOSE_FILE" ]]; then
    ok "COMPOSE_FILE points at the repo compose"
else
    bad "COMPOSE_FILE: $COMPOSE_FILE"
fi
if (unset CODESPACE_NAME GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN; require_codespace >/dev/null 2>&1); then
    bad "require_codespace must fail outside a codespace"
else
    ok "require_codespace rejects non-codespace environments"
fi
if printf 'DB_PASSWORD=secret123\n' > /tmp/cs-env-test && CODESPACE_ENV=/tmp/cs-env-test codespace_env_get DB_PASSWORD | grep -q '^secret123$'; then
    ok "codespace_env_get reads the env file"
else
    bad "codespace_env_get"
fi
rm -f /tmp/cs-env-test

echo
echo "Codespace tests: ${pass} passed, ${fail} failed."
exit "$fail"
