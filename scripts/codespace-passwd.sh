#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-passwd.sh
# Set (or rotate) the admin password of the Codespace panel and persist it in
# .codespace/.env so the printed summary and future runs stay consistent.
#
# Usage:
#   bash scripts/codespace-passwd.sh                 # random 20-char password
#   bash scripts/codespace-passwd.sh 'MyNewPass123'  # choose your own
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/codespace-common.sh"

main() {
    require_codespace
    [[ -f "$CODESPACE_ENV" ]] || die "Run bash scripts/codespace-up.sh first."

    local new_pass
    new_pass="${1:-$(gen_password 20)}"
    if [[ "${#new_pass}" -lt 8 ]]; then
        die "password must be at least 8 characters."
    fi

    log "Updating password for the 'admin' user inside the panel container"
    local result
    result=$(compose exec -T -e NEWPASS="$new_pass" panel php artisan tinker --no-interaction <<'PHP'
$u = Pterodactyl\Models\User::where('username', 'admin')->first();
if (!$u) { echo 'NO_ADMIN_USER'; exit(1); }
$u->password = Hash::make(getenv('NEWPASS'));
$u->save();
echo 'PASSWORD_UPDATED';
PHP
)
    grep -q PASSWORD_UPDATED <<<"$result" || { echo "$result" >&2; die "could not update the admin password."; }

    # Persist alongside the other secrets (env file stays mode 600).
    local tmp
    tmp=$(mktemp)
    grep -v '^ADMIN_PASSWORD=' "$CODESPACE_ENV" > "$tmp" || true
    printf 'ADMIN_PASSWORD=%s\n' "$new_pass" >> "$tmp"
    umask 077
    mv "$tmp" "$CODESPACE_ENV"

    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"
    cat <<EOF

${C_BOLD}Admin password updated${C_RESET}
  Panel URL : ${PANEL_PUBLIC_URL}
  Username  : admin
  Password  : ${new_pass}
  Stored in : ${CODESPACE_ENV}
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
