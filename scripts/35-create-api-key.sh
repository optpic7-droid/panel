#!/usr/bin/env bash
# =============================================================================
# scripts/35-create-api-key.sh
# Creates a full-permission Pterodactyl Application API key (ptla_...) on an
# already-installed panel, using Laravel's KeyCreationService through tinker.
# The plaintext key is shown ONCE and stored in /root/.petro-panel.env so the
# node connector (30-connect-node.sh) can run non-interactively.
#
# Usage:
#   sudo bash scripts/35-create-api-key.sh          # reuse stored key if present
#   sudo bash scripts/35-create-api-key.sh --new    # force a fresh key
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

SECRET_FILE=/root/.petro-panel.env

create_key() {
    [[ -f "${PANEL_PATH}/artisan" ]] || die "No panel found at ${PANEL_PATH} - run './install.sh panel' first."
    cd "$PANEL_PATH" || return 1

    log "Creating a full-permission Application API key"
    # AdminAcl::READ | WRITE = 3 for every resource, mirroring the admin UI.
    local plain
    plain=$(php artisan tinker --no-interaction <<'PHP'
$admin = Pterodactyl\Models\User::where('root_admin', true)->orderBy('id')->first();
if (is_null($admin)) { fwrite(STDERR, "no admin user found\n"); exit(1); }
$permissions = [];
foreach (Pterodactyl\Services\Acl\Api\AdminAcl::getResourceList() as $resource) {
    $permissions['r_' . $resource] = Pterodactyl\Services\Acl\Api\AdminAcl::READ | Pterodactyl\Services\Acl\Api\AdminAcl::WRITE;
}
$model = app(Pterodactyl\Services\Api\KeyCreationService::class)
    ->setKeyType(Pterodactyl\Models\ApiKey::TYPE_APPLICATION)
    ->handle(['memo' => 'petro-installer auto key', 'user_id' => $admin->id], $permissions);
echo $model->identifier . decrypt($model->token), PHP_EOL;
PHP
) || die "tinker failed while creating the API key"

    [[ "$plain" == ptla_* ]] || die "unexpected key output: ${plain:0:12}..."
    printf '%s' "$plain"
}

main() {
    load_config
    require_root

    if [[ "${1:-}" != "--new" ]]; then
        if existing=$(read_secret APPLICATION_API_KEY 2>/dev/null) && [[ "$existing" == ptla_* ]]; then
            log "Reusing existing APPLICATION_API_KEY from ${SECRET_FILE}"
            echo "$existing"
            return 0
        fi
    fi

    local key
    key=$(create_key)
    persist_secret APPLICATION_API_KEY "$key"

    echo
    log "Application API key created (full read/write):"
    echo "  ${key}"
    log "Saved to ${SECRET_FILE}. Shown only once - store it securely if needed elsewhere."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
