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
# MariaDB healthcheck must use an image-native command (healthcheck.sh flags
# differ across versions and previously marked the container unhealthy).
db_health = svc["database"]["healthcheck"]["test"]
assert any("mariadb-admin" in part for part in db_health), db_health
assert "start_period" in svc["database"]["healthcheck"]
assert "--default-authentication-plugin" not in str(svc["database"]), "remove unsupported db flag"
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

echo "== require_codespace recovery (sudo su strips env vars) =="
# Build a fake PID-1 environment file (NUL-separated, like /proc/*/environ).
fake_environ=$(mktemp /tmp/fake-environ.XXXXXX)
{
    printf 'CODESPACE_NAME=crispy-recovery-abc\0'
    printf 'GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN=app.github.dev\0'
    printf 'OTHER_VAR=keepme\0'
} > "$fake_environ"
if ( unset CODESPACE_NAME GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN
     PROC_ENVIRON="$fake_environ"
     # shellcheck disable=SC1091
     source scripts/codespace-common.sh
     require_codespace
     [[ "$CODESPACE_NAME" == "crispy-recovery-abc" ]] \
       && [[ "$GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN" == "app.github.dev" ]] ); then
    ok "recovers CODESPACE_NAME from PID 1 environment after sudo su"
else
    bad "PID-1 environment recovery"
fi
# Default forwarding domain when only CODESPACE_NAME is recoverable.
if ( unset CODESPACE_NAME GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN
     printf 'CODESPACE_NAME=only-name-xyz\0' > "$fake_environ"
     PROC_ENVIRON="$fake_environ"
     # shellcheck disable=SC1091
     source scripts/codespace-common.sh
     require_codespace
     [[ "$GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN" == "app.github.dev" ]] ); then
    ok "defaults forwarding domain to app.github.dev"
else
    bad "default forwarding domain"
fi
# Hard failure when nothing is recoverable and gh is unavailable.
if ( unset CODESPACE_NAME GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN
     # shellcheck disable=SC2123,SC2030  # intentionally hide every external binary
     PATH=/nonexistent PROC_ENVIRON=/nonexistent/environ
     # shellcheck disable=SC1091
     source scripts/codespace-common.sh
     require_codespace ) >/dev/null 2>&1; then
    bad "require_codespace should fail without any recoverable identity"
else
    ok "fails clearly outside a Codespace with no recovery path"
fi
rm -f "$fake_environ"

echo "== resolve_panel_image pins v1 and falls back safely =="
stub_dir=$(mktemp -d /tmp/fake-docker.XXXXXX)
# Fake docker: manifest inspect succeeds only for the v1.11.9 tag.
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    ghcr.io/pterodactyl/panel:v1.11.9) exit 0 ;;
    ghcr.io/*) exit 1 ;;
  esac
done
exit 1
STUB
chmod +x "$stub_dir/docker"
# shellcheck disable=SC2031  # PATH override is intentionally local to the subshell
if [[ "$(PATH="$stub_dir:$PATH" resolve_panel_image)" == "ghcr.io/pterodactyl/panel:v1.11.9" ]]; then
    ok "picks an available v1 tag instead of :latest"
else
    # shellcheck disable=SC2031
    bad "v1 tag selection: $(PATH="$stub_dir:$PATH" resolve_panel_image)"
fi
# Fake docker that rejects every manifest -> :latest fallback.
cat > "$stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
# shellcheck disable=SC2031
if [[ "$(PATH="$stub_dir:$PATH" resolve_panel_image)" == "ghcr.io/pterodactyl/panel:latest" ]]; then
    ok "falls back to :latest when no v1 tag is published"
else
    bad "latest fallback failed"
fi
rm -rf "$stub_dir"

echo
echo "Codespace tests: ${pass} passed, ${fail} failed."
exit "$fail"
