#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-errors.sh
# Compact, read-only triage for web errors (e.g. the login page's
# "An unexpected error was encountered"). Prints the real Laravel exception,
# tests a Redis session write end-to-end from PHP, and tails nginx/PHP logs.
# Safe to run any number of times; changes nothing.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/codespace-common.sh"

# Single-quoted sh -c blocks intentionally expand inside the container.
# shellcheck disable=SC2016

main() {
    require_codespace
    [[ -f "$CODESPACE_ENV" ]] || die "Run bash scripts/codespace-up.sh first."

    echo "== 1. container state =="
    compose ps -a || true

    echo
    echo "== 2. last Laravel exceptions (the real cause of the web 500) =="
    compose exec -T panel sh -c '
        LOG=/app/storage/logs/laravel.log
        if [ -f "$LOG" ]; then
            grep -n "production.ERROR\|local.ERROR" "$LOG" | tail -5 || echo "(no ERROR lines logged yet)"
            echo "---- last 45 lines ----"
            tail -n 45 "$LOG"
        else
            echo "no laravel.log"; ls -la /app/storage/logs 2>/dev/null || true
        fi
    ' || true

    echo
    echo "== 3. end-to-end Redis session write test from PHP =="
    compose exec -T panel php artisan tinker --no-interaction <<'PHP'
try {
    session()->put('diag_test', 'ok');
    session()->save();
    echo 'SESSION_WRITE_OK driver=' . config('session.driver') . PHP_EOL;
    echo 'CACHE_STORE=' . config('cache.default') . ' QUEUE=' . config('queue.default') . PHP_EOL;
} catch (\Throwable $e) {
    echo 'SESSION_WRITE_FAIL: ' . get_class($e) . ': ' . $e->getMessage() . PHP_EOL;
}
PHP

    echo
    echo "== 4. PHP redis extension and DB connectivity =="
    compose exec -T panel php artisan tinker --no-interaction <<'PHP'
echo 'redis ext: ' . (extension_loaded('redis') ? 'phpredis' : (class_exists('Predis\Client') ? 'predis' : 'NONE')) . PHP_EOL;
try { \DB::connection()->getPdo(); echo 'DB_OK server=' . \DB::selectOne('select version() v')->v . PHP_EOL; }
catch (\Throwable $e) { echo 'DB_FAIL: ' . $e->getMessage() . PHP_EOL; }
PHP

    echo
    echo "== 5. nginx + supervisord (php-fpm) log tails =="
    compose exec -T panel sh -c '
        for f in /var/log/nginx/error.log /var/log/php7/error.log /var/log/supervisord/supervisord.log; do
            [ -f "$f" ] && { echo "---- $f ----"; tail -n 15 "$f"; }
        done
    ' || true

    echo
    log "Paste everything above back - section 2 names the exact failing line."
}

main "$@"
