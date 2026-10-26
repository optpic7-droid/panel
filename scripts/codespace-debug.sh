#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-debug.sh
# Read-only diagnostics for the Codespace Pterodactyl stack. Pinpoints whether
# the panel entrypoint's hang is DNS or TCP routing between containers.
# Safe to run any number of times; changes nothing.
# Single-quoted sh -c blocks intentionally expand inside the container.
# shellcheck disable=SC2016
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
    echo "== 2. panel image and DB env seen by the panel container =="
    echo "image: $PANEL_IMAGE"
    compose exec -T panel sh -c 'env | grep -E "^(DB_HOST|DB_PORT|REDIS_HOST)=" | sort' || true

    echo
    echo "== 3. network: subnet, gateway and container IPs =="
    docker network inspect pterodactyl_stack \
        -f 'subnet={{range .IPAM.Config}}{{.Subnet}} gw={{.Gateway}}{{end}}' 2>/dev/null || true
    docker network inspect pterodactyl_stack \
        -f '{{range .Containers}}{{.Name}} -> {{.IPv4Address}}{{println}}{{end}}' 2>/dev/null || true

    echo "== 4. panel container DNS config and routing table =="
    # shellcheck disable=SC2016
    compose exec -T panel sh -c '
        echo "-- /etc/resolv.conf --"; cat /etc/resolv.conf
        echo "-- routes --"; (ip route || route -n || cat /proc/net/route) 2>/dev/null
        echo "-- tools --"; command -v nc || echo "nc MISSING"; command -v getent || echo "getent MISSING"
    ' || true

    echo
    echo "== 5. name resolution inside panel =="
    # shellcheck disable=SC2016
    compose exec -T panel sh -c '
        for name in database cache; do
            echo "-- getent hosts $name --"
            getent hosts "$name" || echo "DNS FAIL for $name"
        done
    ' || true

    echo
    echo "== 6a. bridge probes (expected to TIME OUT in the Codespace DinD VM) =="
    # shellcheck disable=SC2016
    compose exec -T panel sh -c '
        echo "-- database:3306 --"; nc -z -v -w5 database 3306; echo "nc db exit=$?"
        echo "-- cache:6379 --";    nc -z -v -w5 cache 6379;    echo "nc redis exit=$?"
        echo "-- embedded DNS 127.0.0.11:53 --"; nc -z -v -w5 127.0.0.11 53; echo "nc dns exit=$?"
    ' || true

    echo
    echo "== 6b. host-gateway probes (the path the stack actually uses) =="
    # shellcheck disable=SC2016
    compose exec -T panel sh -c '
        echo "-- host.docker.internal -> 3306 (MariaDB) --"; nc -z -v -w5 host.docker.internal 3306; echo "exit=$?"
        echo "-- host.docker.internal -> 6379 (Redis) --";   nc -z -v -w5 host.docker.internal 6379; echo "exit=$?"
        echo "-- host.docker.internal -> 8080 (panel) --";   nc -z -v -w5 host.docker.internal 8080; echo "exit=$?"
    ' || true

    echo
    echo "== 7. what is listening inside the database container =="
    compose exec -T database sh -c '(netstat -ltn 2>/dev/null || ss -ltn 2>/dev/null) | grep -E "3306|LISTEN"' || true

    echo
    echo "== 8. last 30 panel entrypoint lines =="
    compose logs --tail 30 panel || true

    echo
    echo "== 9. Laravel application exceptions (the real login/500 cause) =="
    compose exec -T panel sh -c '
        LOG=/app/storage/logs/laravel.log
        if [ -f "$LOG" ]; then
            # Print the most recent stack trace block.
            grep -n "production.ERROR\|local.ERROR" "$LOG" | tail -3 || true
            echo "---- tail ----"
            tail -n 50 "$LOG"
        else
            echo "no laravel.log yet"; ls -la /app/storage/logs 2>/dev/null || true
        fi
    ' || true

    echo
    echo "== 10. session/Redis path and app key sanity =="
    # shellcheck disable=SC2016
    compose exec -T panel sh -c '
        echo "-- redis TCP --"; nc -z -v -w5 host.docker.internal 6379; echo "exit=$?"
        echo "-- session driver / app key --"
        grep -E "^(SESSION_DRIVER|CACHE_DRIVER|APP_KEY|APP_URL)=" /app/var/.env 2>/dev/null \
            | sed "s/APP_KEY=.*/APP_KEY=<present>/" || echo "/app/var/.env missing"
        echo "-- redis ping from PHP --"
        php -r "require \"/app/vendor/autoload.php\"; \$r=new Predis\\Client([\"host\"=>\"host.docker.internal\"]); echo \$r->ping(), PHP_EOL;" 2>/dev/null \
            || echo "(predis ping unavailable - TCP result above is what matters)"
    ' || true

    echo
    log "Copy EVERYTHING above and paste it back - it shows the exact failure."
}

main "$@"
