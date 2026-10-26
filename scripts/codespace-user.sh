#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-user.sh
# Self-service account manager for the Codespace panel.
#
# Stock Pterodactyl has no public sign-up page (accounts are created by
# admins), so this script lets you create YOUR OWN account with credentials
# you choose, and grant/revoke administrator on any existing user.
#
# Usage:
#   bash scripts/codespace-user.sh create                 # interactive prompts
#   bash scripts/codespace-user.sh create --admin         # create as administrator
#   bash scripts/codespace-user.sh create --username ajay --email a@b.c \
#        --name-first Ajay --name-last Kumar --password 'Secret123' --admin
#   bash scripts/codespace-user.sh promote  <username>    # grant administrator
#   bash scripts/codespace-user.sh demote   <username>    # revoke administrator
#   bash scripts/codespace-user.sh list                   # show accounts
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/codespace-common.sh"

# Pure validation helpers (also covered by offline tests).
validate_username() {
    local u=$1
    [[ "$u" =~ ^[A-Za-z0-9_.\-]{3,32}$ ]]
}

validate_email() {
    local e=$1
    [[ "$e" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]
}

validate_password() {
    # At least 8 characters; Pterodactyl itself enforces the same minimum.
    [[ "${#1}" -ge 8 ]]
}

user_exists() {
    local username=$1
    compose exec -T panel php artisan tinker --no-interaction <<PHP | grep -q EXISTS
echo Pterodactyl\\Models\\User::where('username', '${username}')->exists() ? 'EXISTS' : 'MISSING';
PHP
}

create_user() {
    local make_admin=0 username="" email="" first="" last="" password=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --admin) make_admin=1; shift ;;
            --username) username=$2; shift 2 ;;
            --email) email=$2; shift 2 ;;
            --name-first) first=$2; shift 2 ;;
            --name-last) last=$2; shift 2 ;;
            --password) password=$2; shift 2 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    if [[ -z "$username" ]]; then read -r -p "Username (3-32 chars, letters/numbers/._-): " username; fi
    if ! validate_username "$username"; then
        die "invalid username '$username': 3-32 chars, only letters, numbers, dot, underscore, dash."
    fi
    if user_exists "$username"; then
        die "username '$username' already exists. Try 'promote $username' instead."
    fi

    if [[ -z "$email" ]]; then read -r -p "Email address: " email; fi
    if ! validate_email "$email"; then die "invalid email address: $email"; fi

    if [[ -z "$first" ]]; then read -r -p "First name: " first; fi
    if [[ -z "$last" ]]; then read -r -p "Last name: " last; fi
    [[ -n "$first" && -n "$last" ]] || die "first and last name are required."

    if [[ -z "$password" ]]; then
        local confirm
        read -r -s -p "Password (min 8 chars, hidden): " password; echo
        read -r -s -p "Confirm password: " confirm; echo
        [[ "$password" == "$confirm" ]] || die "passwords did not match - nothing was created."
    fi
    validate_password "$password" || die "password must be at least 8 characters."

    log "Creating account '${username}' (admin: $([[ $make_admin -eq 1 ]] && echo yes || echo no))"
    compose exec -T panel php artisan p:user:make \
        --email="$email" --username="$username" \
        --name-first="$first" --name-last="$last" \
        --password="$password" --admin="$make_admin"

    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"
    cat <<EOF

${C_BOLD}Account ready${C_RESET}
  Panel URL : ${PANEL_PUBLIC_URL}
  Username  : ${username}
  Password  : ${password}
  Admin     : $([[ $make_admin -eq 1 ]] && echo "yes (root administrator)" || echo "no - promote with: codespace-user.sh promote ${username}")
EOF
}

set_admin() {
    local mode=$1 username=$2
    [[ -n "$username" ]] || die "usage: codespace-user.sh ${mode} <username>"
    local flag value
    if [[ "$mode" == "promote" ]]; then flag=1; value="true"; else flag=0; value="false"; fi

    local result
    result=$(compose exec -T -e TARGET_USER="$username" -e TARGET_FLAG="$flag" \
        panel php artisan tinker --no-interaction <<'PHP'
$u = Pterodactyl\Models\User::where('username', getenv('TARGET_USER'))->first();
if (!$u) { echo 'NO_USER'; exit(1); }
$u->root_admin = (bool) getenv('TARGET_FLAG');
$u->save();
echo 'ADMIN_SET';
PHP
)
    grep -q ADMIN_SET <<<"$result" || { echo "$result" >&2; die "could not update '$username' (does the user exist?)."; }
    log "User '${username}' root_admin is now ${value}."
}

list_users() {
    compose exec -T panel php artisan tinker --no-interaction <<'PHP'
foreach (Pterodactyl\Models\User::orderBy('id')->get() as $u) {
    echo sprintf("%-20s %-30s admin=%s\n", $u->username, $u->email, $u->root_admin ? 'yes' : 'no');
}
PHP
}

usage() {
    cat <<'EOF'
Account manager for the Codespace panel (stock Pterodactyl has no sign-up page):
  create [--admin] [--username .. --email .. --name-first .. --name-last .. --password ..]
  promote <username>     grant administrator
  demote  <username>     revoke administrator
  list                   list every account and its admin flag
EOF
}

main() {
    require_codespace
    [[ -f "$CODESPACE_ENV" ]] || die "Run bash scripts/codespace-up.sh first."
    local cmd=${1:-}
    case "$cmd" in
        create) shift; create_user "$@" ;;
        promote) shift; set_admin promote "${1:-}" ;;
        demote) shift; set_admin demote "${1:-}" ;;
        list) list_users ;;
        ""|-h|--help|help) usage ;;
        *) usage; die "unknown command: $cmd" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
