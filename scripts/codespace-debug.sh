#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-debug.sh
# One-shot diagnostics for the Codespace Pterodactyl stack. Safe, read-only:
# shows container state, panel entrypoint progress and tests the panel->DB
# network path from INSIDE the panel container (the usual failure point).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/codespace-common.sh"

main() {
    require_codespace
    [[ -f "$CODESPACE_ENV" ]] || die "No ${CODESPACE_ENV} - run codespace-up.sh first."
    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"

    echo "== 1. container state =="
    compose ps -a || true

    echo
    echo "== 2. panel image in use =="
    echo "$PANEL_IMAGE"

    echo
    echo "== 3. last 40 panel entrypoint lines =="
    compose logs --tail 40 panel || true

    echo
    echo "== 4. tools available inside the panel container =="
    compose exec -T panel sh -c 'command -v nc || echo "nc MISSING"; command -v php || echo "php MISSING"' || true

    echo
    echo "== 5. DNS + TCP path panel -> database:3306 =="
    # shellcheck disable=SC2016  # expansion must happen inside the container
    compose exec -T panel sh -c '
        echo "-- DNS lookup of service name --"
        (getent hosts database || nslookup database 2>/dev/null || ping -c1 -W2 database 2>&1 | head -2) || echo "DNS FAILED"
        echo "-- TCP probe --"
        if command -v nc >/dev/null; then
            nc -z -v -w5 database 3306; echo "nc exit=$?"
        else
            php -r "\$f=@fsockopen(\"database\",3306,\$e,\$s,5); echo \$f?\"TCP OK\n\":\"TCP FAIL: \$s\n\";"
        fi
    ' || true

    echo
    echo "== 6. MariaDB databases and users (from the DB container) =="
    compose exec -T database mariadb -uroot -p"$DB_ROOT_PASSWORD" \
        -e "SHOW DATABASES; SELECT user,host FROM mysql.user;" 2>&1 | sed 's/^/  /' || true

    echo
    echo "== 7. can the panel container reach the web port locally? =="
    compose exec -T panel sh -c 'wget -qO- -T5 http://127.0.0.1/ >/dev/null && echo "internal nginx OK" || echo "internal nginx not ready"' || true

    echo
    log "Send the full output above if the stack is still failing."
}

main "$@"
