#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-errors.sh
# Compact, read-only triage for web errors (e.g. the login page's
# "An unexpected error was encountered"). Handles the panel's DAILY log
# channel (laravel-YYYY-MM-DD.log, not laravel.log), reproduces a login POST
# inside the container, and prints the fresh exception it produces.
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
    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"

    # Optional: codespace-errors.sh <username> <password> to reproduce login.
    local login_user="${1:-yash}" login_pass="${2:-Yash@12345}"

    echo "== 1. container state =="
    compose ps -a || true

    echo
    echo "== 2. newest Laravel log and its latest exceptions =="
    compose exec -T panel sh -c '
        LOG=$(ls -1t /app/storage/logs/laravel*.log 2>/dev/null | head -1)
        if [ -z "$LOG" ]; then echo "no laravel logs yet"; ls -la /app/storage/logs 2>/dev/null; exit 0; fi
        echo "log file: $LOG"
        grep -n "production.ERROR\|local.ERROR" "$LOG" | tail -6 || echo "(no ERROR lines)"
        echo "---- last 50 lines ----"
        tail -n 50 "$LOG"
    ' || true

    echo
    echo "== 3. end-to-end Redis session write test from PHP =="
    compose exec -T panel php artisan tinker --no-interaction <<'PHP' || true
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
    echo "== 4. redis extension and DB connectivity (one-liners) =="
    compose exec -T panel php artisan tinker --no-interaction \
        --execute="echo 'redis ext: ' . (extension_loaded('redis') ? 'phpredis' : (class_exists('Predis\Client') ? 'predis' : 'NONE')) . PHP_EOL;" || true
    compose exec -T panel php artisan tinker --no-interaction \
        --execute="echo 'DB_OK ' . \DB::selectOne('select version() v')->v . PHP_EOL;" || true
    compose exec -T panel php artisan tinker --no-interaction \
        --execute="echo 'users=' . \Pterodactyl\Models\User::count() . ' recaptcha=' . config('pterodactyl.recaptcha.enabled') . PHP_EOL;" || true

    echo
    echo "== 5. LIVE login reproduction (${login_user}) against the local web server =="
    compose exec -T -e LU="$login_user" -e LP="$login_pass" panel sh -c '
        curl -s -o /tmp/login.json -w "HTTP %{http_code}\n" \
          -X POST http://127.0.0.1/auth/login \
          -H "Accept: application/json" -H "Content-Type: application/json" \
          --data "{\"user\":\"$LU\",\"password\":\"$LP\"}"
        echo "---- response body ----"; cat /tmp/login.json 2>/dev/null; echo
    ' || true

    echo
    echo "== 6. exception produced by the login attempt above =="
    compose exec -T panel sh -c '
        LOG=$(ls -1t /app/storage/logs/laravel*.log 2>/dev/null | head -1)
        [ -z "$LOG" ] && { echo "no log"; exit 0; }
        # Print from the last ERROR marker to end of file.
        LINE=$(grep -n "production.ERROR\|local.ERROR" "$LOG" | tail -1 | cut -d: -f1)
        if [ -n "$LINE" ]; then tail -n +"$LINE" "$LOG" | head -40; else echo "no new ERROR line - login may have succeeded"; fi
    ' || true

    echo
    echo "== 7. nginx + supervisord (php-fpm) log tails =="
    compose exec -T panel sh -c '
        for f in /var/log/nginx/error.log /var/log/php7/error.log /var/log/supervisord/supervisord.log; do
            [ -f "$f" ] && { echo "---- $f ----"; tail -n 12 "$f"; }
        done
    ' || true

    echo
    log "Paste everything above back - sections 5-6 show the exact login failure."
}

main "$@"
