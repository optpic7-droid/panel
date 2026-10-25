#!/usr/bin/env bash
# =============================================================================
# scripts/10-install-panel.sh
# Installs the Pterodactyl ("petro") Panel: PHP, MariaDB, Redis, Nginx,
# Composer, the panel application, queue worker and (optionally) Let's Encrypt.
# Safe to re-run: existing databases, files and admin users are left in place.
# Target: Debian 11/12 or Ubuntu 20.04/22.04/24.04, fresh server, as root.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# External URL of the panel, including a non-standard port.
panel_url() {
    local scheme=http
    [[ "${PANEL_SSL}" == "true" ]] && scheme=https
    if [[ "${PANEL_PORT}" == "80" || ( "${PANEL_SSL}" == "true" && "${PANEL_PORT}" == "443" ) ]]; then
        echo "${scheme}://${PANEL_FQDN}"
    else
        echo "${scheme}://${PANEL_FQDN}:${PANEL_PORT}"
    fi
}

main() {
    load_config
    require_root
    detect_os
    require_vars PANEL_FQDN
    install_packages
    setup_database
    install_panel_files
    configure_panel
    make_admin_user
    configure_nginx
    configure_services
    issue_certificate
    finalize

    log "Panel installation finished."
    echo
    log "URL:      $(panel_url)"
    log "Login:    ${ADMIN_USERNAME}"
    if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
        log "Password: ${ADMIN_PASSWORD}"
    else
        log "Password: (the one generated above / stored in /root/.petro-panel.env)"
    fi
}

install_packages() {
    apt_update
    apt_install ca-certificates curl apt-transport-https gnupg lsb-release \
                software-properties-common unzip tar git cron jq

    # ---- PHP repository (8.3 on every supported distro) ---------------------
    if [[ "$OS_ID" == "debian" ]]; then
        if [[ ! -f /etc/apt/sources.list.d/php-sury.list ]]; then
            log "Adding sury.org PHP repository"
            curl -fsSL https://packages.sury.org/php/apt.gpg \
                | gpg --dearmor -o /usr/share/keyrings/php-sury-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/php-sury-keyring.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
                > /etc/apt/sources.list.d/php-sury.list
        fi
    else
        log "Adding ondrej/php PPA"
        add-apt-repository -y ppa:ondrej/php
    fi
    apt_update

    local php="php${PHP_VERSION}"
    apt_install "${php}" "${php}-cli" "${php}-common" "${php}-gd" "${php}-mysql" \
                "${php}-mbstring" "${php}-bcmath" "${php}-xml" "${php}-fpm" \
                "${php}-curl" "${php}-zip" "${php}-intl" "${php}-readline" \
                mariadb-server nginx redis-server
    apt_install certbot python3-certbot-nginx || warn "certbot packages missing - SSL step will be skipped if unavailable."

    systemctl enable --now mariadb redis-server
}

setup_database() {
    if [[ -z "${DB_PASSWORD:-}" ]]; then
        if DB_PASSWORD=$(read_secret DB_PASSWORD 2>/dev/null) && [[ -n "$DB_PASSWORD" ]]; then
            log "Reusing DB_PASSWORD from /root/.petro-panel.env"
        else
            DB_PASSWORD=$(gen_password)
            persist_secret DB_PASSWORD "$DB_PASSWORD"
        fi
    fi
    log "Configuring MariaDB database '${DB_NAME}' and user '${DB_USER}'"
    mysql --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

install_panel_files() {
    local marker="${PANEL_PATH}/.petro-version"
    if [[ -f "$marker" && $(cat "$marker") == "${PANEL_VERSION}" ]]; then
        log "Panel ${PANEL_VERSION} already extracted in ${PANEL_PATH}, skipping download."
        return
    fi

    log "Downloading Pterodactyl Panel ${PANEL_VERSION}"
    local tmp_tar; tmp_tar=$(mktemp /tmp/panel.XXXXXX.tar.gz)
    curl -fL --retry 3 -o "$tmp_tar" \
        "https://github.com/pterodactyl/panel/releases/download/${PANEL_VERSION}/panel.tar.gz"

    mkdir -p "$PANEL_PATH"
    tar -xzf "$tmp_tar" -C "$PANEL_PATH"
    rm -f "$tmp_tar"
    chmod -R 755 "${PANEL_PATH}/storage" "${PANEL_PATH}/bootstrap/cache" 2>/dev/null || true
    echo "${PANEL_VERSION}" > "$marker"

    # ---- Composer -----------------------------------------------------------
    if ! command -v composer >/dev/null; then
        log "Installing Composer"
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi
}

configure_panel() {
    cd "$PANEL_PATH" || return 1
    [[ -f .env ]] || cp .env.example .env

    log "Installing PHP dependencies"
    composer install --no-dev --optimize-autoloader --no-interaction

    php artisan key:generate --force

    log "Writing environment configuration"
    php artisan p:environment:setup \
        --url="$(panel_url)" \
        --timezone="${TIMEZONE}" \
        --cache=redis --session=redis --queue=redis \
        --redis-host=127.0.0.1 --redis-port=6379 --redis-pass="" \
        --telemetry=false

    php artisan p:environment:database \
        --host=127.0.0.1 --port=3306 \
        --database="${DB_NAME}" --username="${DB_USER}" --password="${DB_PASSWORD}"

    log "Running database migrations and seeders"
    php artisan migrate --seed --force

    chown -R www-data:www-data "$PANEL_PATH"
    chmod -R 755 "${PANEL_PATH}/storage" "${PANEL_PATH}/bootstrap/cache" 2>/dev/null || true
}

make_admin_user() {
    require_vars ADMIN_EMAIL ADMIN_USERNAME ADMIN_FIRSTNAME ADMIN_LASTNAME
    cd "$PANEL_PATH" || return 1

    local exists
    exists=$(mysql --protocol=socket -N -B \
        -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.users WHERE email='${ADMIN_EMAIL}';" 2>/dev/null || echo 0)
    if [[ "$exists" != "0" ]]; then
        warn "Admin user '${ADMIN_EMAIL}' already exists, leaving it untouched."
        return
    fi

    if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
        ADMIN_PASSWORD=$(gen_password 24)
        persist_secret ADMIN_PASSWORD "$ADMIN_PASSWORD"
    fi

    log "Creating admin user '${ADMIN_USERNAME}'"
    php artisan p:user:make \
        --email="${ADMIN_EMAIL}" \
        --username="${ADMIN_USERNAME}" \
        --name-first="${ADMIN_FIRSTNAME}" \
        --name-last="${ADMIN_LASTNAME}" \
        --password="${ADMIN_PASSWORD}" \
        --admin=1
}

configure_nginx() {
    # Always start from the HTTP template: when PANEL_SSL=true, certbot's
    # nginx plugin rewrites this very file with the 443/certificate block.
    # Installing the SSL template before the certificate exists would fail
    # 'nginx -t'. configs/nginx/pterodactyl-ssl.conf is the reference layout.
    log "Installing Nginx site for ${PANEL_FQDN} on port ${PANEL_PORT} (HTTP)"
    sed -e "s|__FQDN__|${PANEL_FQDN}|g" \
        -e "s|__PANEL_PORT__|${PANEL_PORT}|g" \
        -e "s|__PHP_SOCKET__|/run/php/php${PHP_VERSION}-fpm.sock|g" \
        -e "s|__PANEL_PATH__|${PANEL_PATH}|g" \
        "${PETRO_ROOT}/configs/nginx/pterodactyl.conf" > /etc/nginx/sites-available/pterodactyl
    ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/pterodactyl
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl restart nginx "php${PHP_VERSION}-fpm"
}

configure_services() {
    log "Installing queue worker (pteroq) and scheduler cron"
    sed "s|__PANEL_PATH__|${PANEL_PATH}|g" \
        "${PETRO_ROOT}/configs/systemd/pteroq.service" > /etc/systemd/system/pteroq.service
    systemctl daemon-reload
    systemctl enable --now pteroq

    local cron_file=/etc/cron.d/pterodactyl
    cat > "$cron_file" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * www-data php ${PANEL_PATH}/artisan schedule:run >> /dev/null 2>&1
EOF
    chmod 644 "$cron_file"
}

issue_certificate() {
    if [[ "${PANEL_SSL}" != "true" ]]; then
        info "PANEL_SSL=false, skipping Let's Encrypt."
        return
    fi
    if [[ "${PANEL_PORT}" != "80" ]]; then
        warn "PANEL_PORT=${PANEL_PORT}: Let's Encrypt HTTP-01 needs port 80, skipping TLS."
        warn "The panel stays reachable at $(panel_url). Set PANEL_PORT=80 for HTTPS."
        return
    fi
    if ! command -v certbot >/dev/null; then
        warn "certbot not available; skipping SSL. Run 'certbot --nginx' manually later."
        return
    fi
    # An IP address cannot get a public certificate.
    if [[ "$PANEL_FQDN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "PANEL_FQDN is an IP address; skipping Let's Encrypt (use a domain or a self-signed cert)."
        return
    fi

    log "Requesting Let's Encrypt certificate for ${PANEL_FQDN}"
    certbot --nginx --non-interactive --agree-tos \
        --email "${LETSENCRYPT_EMAIL:-admin@${PANEL_FQDN}}" \
        -d "$PANEL_FQDN" --redirect
    systemctl restart nginx
}

finalize() {
    cd "$PANEL_PATH" || return 1
    php artisan config:clear || true
    php artisan config:cache
    systemctl restart pteroq nginx "php${PHP_VERSION}-fpm"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
