#!/usr/bin/env bash
# =============================================================================
# tests/smoke.sh - static validation that runs on any machine (no root, no apt).
# Checks shell syntax, shellcheck lints (when available) and Node syntax, and
# executes the preflight checker as a functional test.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== bash syntax =="
mapfile -t scripts < <(find . -name '*.sh' -not -path './.git/*' | sort)
for s in "${scripts[@]}"; do
    bash -n "$s"
    echo "  OK  $s"
done

echo "== shellcheck =="
SHELLCHECK=""
command -v shellcheck >/dev/null && SHELLCHECK=shellcheck
[[ -x "$HOME/.local/bin/shellcheck" ]] && SHELLCHECK="$HOME/.local/bin/shellcheck"
if [[ -n "$SHELLCHECK" ]]; then
    "$SHELLCHECK" -x scripts/lib.sh "${scripts[@]}"
    echo "  OK  shellcheck passed"
else
    echo "  SKIP (install shellcheck or: pip install --user shellcheck-py)"
fi

echo "== node syntax =="
node --check scripts/preflight.mjs
echo "  OK  scripts/preflight.mjs"
node --check demo/server.mjs
echo "  OK  demo/server.mjs"

echo "== python syntax =="
python3 -m py_compile scripts/render-config.py
echo "  OK  scripts/render-config.py"

echo "== functional: preflight =="
node scripts/preflight.mjs || true

echo "== unit tests =="
bash tests/unit.sh

echo "== integration tests (mock panel API) =="
bash tests/integration.sh

echo "== demo server tests (runnable preview) =="
bash tests/demo.sh

echo "== config placeholders =="
grep -q '__FQDN__' configs/nginx/pterodactyl.conf
grep -q '__PHP_SOCKET__' configs/nginx/pterodactyl-ssl.conf
grep -q '__PANEL_PATH__' configs/systemd/pteroq.service
echo "  OK  templates contain expected placeholders"

echo
echo "All smoke checks completed."
