#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-debug.sh
# Read-only diagnostics for the Codespace Pterodactyl stack. Pinpoints whether
# the panel entrypoint's hang is DNS or TCP routing between containers.
# Safe to run any number of times; changes nothing.
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
    echo "== 6. TCP probes from panel (5s timeout each) =="
    # shellcheck disable=SC2016
    compose exec -T panel sh -c '
        echo "-- database:3306 --"; nc -z -v -w5 database 3306; echo "nc db exit=$?"
        echo "-- cache:6379 --";    nc -z -v -w5 cache 6379;    echo "nc redis exit=$?"
        echo "-- embedded DNS 127.0.0.11:53 --"; nc -z -v -w5 127.0.0.11 53; echo "nc dns exit=$?"
    ' || true

    echo
    echo "== 7. what is listening inside the database container =="
    compose exec -T database sh -c '(netstat -ltn 2>/dev/null || ss -ltn 2>/dev/null) | grep -E "3306|LISTEN"' || true

    echo
    echo "== 8. last 30 panel entrypoint lines =="
    compose logs --tail 30 panel || true

    echo
    log "Copy EVERYTHING above and paste it back - it shows the exact failure."
}

main "$@"
