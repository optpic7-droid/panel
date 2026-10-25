#!/usr/bin/env bash
# =============================================================================
# scripts/40-theme-arix.sh
# Installs (or removes) the commercial Arix Pterodactyl theme on top of a
# panel already deployed by 10-install-panel.sh.
#
# Arix is a paid, proprietary theme (https://arix.gg, also sold on
# BuiltByBit). This script never downloads "nulled"/leaked copies - you must
# supply your own licensed archive:
#   ARIX_ZIP=/path/to/arix.zip            (a file already on the server)
#   ARIX_SOURCE_URL=https://.../arix.zip (signed download from your account)
#
# Usage:
#   sudo ./install.sh theme               # install/upgrade from ARIX_ZIP/URL
#   sudo ARIX_ZIP=/root/arix.zip bash scripts/40-theme-arix.sh
#   sudo bash scripts/40-theme-arix.sh --uninstall   # restore last backup
#
# A timestamped code backup is written before every install, so the stock
# panel can always be restored.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# Extra frontend packages Arix adds on top of stock Pterodactyl (documented in
# the theme's own install instructions). Override with ARIX_EXTRA_PACKAGES.
DEFAULT_ARIX_PACKAGES=(
    cronstrue jszip react-turnstile
    @dnd-kit/core @dnd-kit/sortable @dnd-kit/utilities
    @types/md5 md5 react-icons@5.4.0 markdown-to-jsx@7.7.10
    i18next-browser-languagedetector@7.2.1
)

backup_dir() {
    echo "${PANEL_PATH%/*}/pterodactyl-backups"
}

# Verify an archive actually contains an Arix/Pterodactyl theme layout.
# Returns 0 when a Pterodactyl-style "artisan" file and a frontend tree exist.
verify_theme_zip() {
    local zip=$1
    [[ -f "$zip" ]] || { warn "archive not found: $zip"; return 1; }
    local listing
    listing=$(unzip -Z1 "$zip" 2>/dev/null) || { warn "not a valid zip: $zip"; return 1; }
    if ! grep -qE '(^|/)artisan$' <<<"$listing"; then
        warn "archive contains no 'artisan' entry - is this the Arix Pterodactyl package?"
        return 1
    fi
    if ! grep -qE '(^|/)resources/scripts/' <<<"$listing"; then
        warn "archive has no resources/scripts/ frontend tree"
        return 1
    fi
    # Reject archives that try to escape the extraction directory.
    if grep -qE '(^|/)\.\.(/|$)' <<<"$listing"; then
        warn "archive contains parent-directory paths - refusing to extract"
        return 1
    fi
    return 0
}

# Find the directory inside an extracted tree that holds the panel root
# (the first directory containing an "artisan" file).
detect_theme_root() {
    local base=$1 candidate
    while IFS= read -r candidate; do
        if [[ -f "$candidate" ]]; then
            dirname "$candidate"
            return 0
        fi
    done < <(find "$base" -type f -name artisan -not -path '*/node_modules/*' | sort)
    return 1
}

# Back up the panel's code directories (user data in storage/ is left alone).
backup_panel() {
    local stamp target
    stamp=$(date +%Y%m%d-%H%M%S)
    target="$(backup_dir)/pterodactyl-${stamp}"
    log "Backing up panel code to ${target}"
    mkdir -p "$target"
    local item
    for item in app bootstrap config database public resources routes \
                artisan composer.json composer.lock package.json yarn.lock .env; do
        [[ -e "${PANEL_PATH}/${item}" ]] && cp -a "${PANEL_PATH}/${item}" "$target/"
    done
    echo "$target"
}

restore_latest_backup() {
    local latest
    latest=$(find "$(backup_dir)" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -n1)
    [[ -n "$latest" ]] || die "No Arix backup found under $(backup_dir)"
    log "Restoring panel from ${latest}"
    cp -a "$latest/." "$PANEL_PATH/"
    rebuild_assets
    log "Stock panel restored. Verify in the browser, then remove old backups if happy."
}

# Shared post-copy steps: PHP deps, migrations, frontend build, caches, rights.
rebuild_assets() {
    cd "$PANEL_PATH" || return 1

    if [[ -f composer.json ]]; then
        log "Refreshing Composer dependencies"
        composer install --no-dev --optimize-autoloader --no-interaction
    fi

    log "Running database migrations"
    php artisan migrate --force

    local packages=("${DEFAULT_ARIX_PACKAGES[@]}")
    # shellcheck disable=SC2153  # ARIX_EXTRA_PACKAGES is user configuration
    if [[ -n "${ARIX_EXTRA_PACKAGES:-}" ]]; then
        read -r -a packages <<<"$ARIX_EXTRA_PACKAGES"
    fi
    log "Installing theme frontend dependencies"
    yarn add "${packages[@]}" --ignore-engines

    log "Building production frontend assets (Node legacy OpenSSL flag)"
    NODE_OPTIONS=--openssl-legacy-provider yarn build:production

    # Arix ships its own artisan command; run it when present.
    if php artisan list 2>/dev/null | grep -qE '(^| )arix$'; then
        log "Running 'php artisan arix install'"
        php artisan arix install
    fi

    log "Clearing and rebuilding caches"
    php artisan optimize:clear
    php artisan optimize

    chown -R www-data:www-data "$PANEL_PATH"
    chmod -R 755 "${PANEL_PATH}/storage" "${PANEL_PATH}/bootstrap/cache" 2>/dev/null || true
}

# Resolve the licensed Arix archive to a local zip path, or fail with guidance.
resolve_arix_archive() {
    if [[ -n "${ARIX_ZIP:-}" ]]; then
        [[ -f "$ARIX_ZIP" ]] || die "ARIX_ZIP set but file missing: $ARIX_ZIP"
        echo "$ARIX_ZIP"
        return 0
    fi
    if [[ -n "${ARIX_SOURCE_URL:-}" ]]; then
        local zip
        zip=$(mktemp /tmp/arix.XXXXXX.zip)
        log "Downloading Arix archive from the configured source URL"
        curl -fL --retry 2 -o "$zip" "$ARIX_SOURCE_URL" || die "download failed"
        echo "$zip"
        return 0
    fi
    cat >&2 <<'EOF'
[error] No Arix archive configured. Arix is commercial software - obtain it from
        https://arix.gg or your BuiltByBit account, upload the zip to the server,
        then re-run with either:
          ARIX_ZIP=/root/arix-theme.zip ./install.sh theme
          ARIX_SOURCE_URL=<signed download url> ./install.sh theme
        Nulled/leaked copies are unsupported and frequently contain backdoors.
EOF
    exit 1
}

install_theme() {
    require_root
    [[ -f "${PANEL_PATH}/artisan" ]] || die "No panel found at ${PANEL_PATH} - run './install.sh panel' first."
    command -v unzip >/dev/null || die "unzip is required (apt install unzip)."
    command -v yarn  >/dev/null || die "yarn is required (the panel installer provides Node.js tooling)."

    local zip
    zip=$(resolve_arix_archive)

    verify_theme_zip "$zip" || die "archive validation failed"

    local work root backup
    work=$(mktemp -d /tmp/arix-extract.XXXXXX)
    trap 'rm -rf "$work"' EXIT
    log "Extracting theme archive"
    unzip -q "$zip" -d "$work"
    root=$(detect_theme_root "$work") || die "could not locate the panel root inside the archive"
    log "Theme root detected: ${root#"$work"}"

    backup=$(backup_panel)

    log "Copying theme files into ${PANEL_PATH}"
    cp -a "$root/." "$PANEL_PATH/"

    rebuild_assets

    echo
    log "Arix theme installed."
    log "Code backup (rollback point): ${backup}"
    log "Roll back with: sudo bash scripts/40-theme-arix.sh --uninstall"
}

main() {
    load_config
    case "${1:-install}" in
        install|"")   install_theme ;;
        --uninstall|uninstall|remove)
            require_root
            [[ -f "${PANEL_PATH}/artisan" ]] || die "No panel found at ${PANEL_PATH}"
            restore_latest_backup ;;
        *) die "unknown argument: $1 (use: install | --uninstall)" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
