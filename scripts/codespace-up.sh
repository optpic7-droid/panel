#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-up.sh
# Boots the REAL Pterodactyl panel (MariaDB + Redis + official panel image +
# Wings) inside a GitHub Codespace via Docker, creates an admin user and a
# connected node, and prints the public browser URL.
#
# Run inside a Codespace:  bash scripts/codespace-up.sh
# Tear down:               bash scripts/codespace-down.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/codespace-common.sh"
# Reuses ensure_location / ensure_node / add_allocations / api_call / payloads.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/30-connect-node.sh"

ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@codespace.local}"
ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME:-Panel}"
ADMIN_LASTNAME="${ADMIN_LASTNAME:-Admin}"

write_env_file() {
    mkdir -p "$CODESPACE_DIR"
    local data_dir="${CODESPACE_DIR}/data"
    mkdir -p "$data_dir"/{database,panel/var,panel/logs,extensions,wings/config,wings/data,wings/logs,wings/tmp}
    chmod 700 "$CODESPACE_DIR"

    local db_root db_pass admin_pass panel_url wings_url
    db_root=$(codespace_env_get DB_ROOT_PASSWORD 2>/dev/null || gen_password)
    db_pass=$(codespace_env_get DB_PASSWORD 2>/dev/null || gen_password)
    admin_pass=$(codespace_env_get ADMIN_PASSWORD 2>/dev/null || gen_password 24)
    panel_url=$(codespace_url 8080)
    wings_url=$(codespace_url 8081)

    local image
    image=$(resolve_blueprint_image)
    umask 077
    cat > "$CODESPACE_ENV" <<EOF
PTERO_DATA_DIR=${data_dir}
BLUEPRINT_IMAGE=${image}
PANEL_IMAGE=${image}
PANEL_PUBLIC_URL=${panel_url}
WINGS_PUBLIC_URL=${wings_url}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${admin_pass}
DB_ROOT_PASSWORD=${db_root}
DB_PASSWORD=${db_pass}
EOF
    log "Environment written to ${CODESPACE_ENV}"
    log "Using Blueprint panel image: ${image}"
}

wait_for_database() {
    log "Waiting for MariaDB to become healthy"
    local cid
    cid=$(compose ps -q database)
    for _ in $(seq 1 60); do
        local status
        status=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo unknown)
        if [[ "$status" == "healthy" ]]; then
            log "MariaDB is healthy."
            return 0
        fi
        if [[ "$status" == "unhealthy" || "$status" == "exited" ]]; then
            warn "Database reported ${status} - recent logs:"
            compose logs --tail 40 database || true
            die "Fix the database error above, then re-run. If the data dir is half-initialized, reset it with: bash scripts/codespace-down.sh --purge"
        fi
        sleep 3
    done
    compose logs --tail 40 database || true
    die "Database did not become healthy in time."
}

preflight_host_gateway() {
    # The Codespace DinD VM drops bridge FORWARD traffic between sibling
    # containers, so the panel reaches MariaDB/Redis through the host gateway
    # via docker-proxy. Verify that path before starting the panel, whose
    # entrypoint would otherwise hang silently on its 'nc' database check.
    log "Probing host-gateway path to MariaDB and Redis via docker-proxy"
    if ! compose run --rm --no-deps --entrypoint sh panel -c '
        nc -z -v -w5 host.docker.internal 3306 || exit 1
        nc -z -v -w5 host.docker.internal 6379 || exit 1
    '; then
        compose logs --tail 20 database cache || true
        die "Cannot reach database/redis through host.docker.internal.
Run 'bash scripts/codespace-debug.sh' and send its output."
    fi
    log "MariaDB and Redis are reachable through host.docker.internal."
}

wait_for_panel() {
    log "Waiting for the panel container to migrate and come online"
    local cid ticks=0
    cid=$(compose ps -q panel)
    for _ in $(seq 1 120); do
        if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:8080/"; then
            log "Panel is responding."
            return 0
        fi
        # Fail fast with real logs when the container is crash-looping.
        local state restarts
        state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)
        restarts=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)
        if [[ "$state" == "exited" || "$restarts" -ge 3 ]]; then
            warn "Panel container is ${state} (restarts=${restarts}) - dumping logs:"
            compose logs --tail 80 panel
            die "Panel container failed to stay up. Run 'bash scripts/codespace-debug.sh' for full diagnostics."
        fi
        # Surface entrypoint progress (migrations can take a minute on first boot).
        ticks=$((ticks + 1))
        if (( ticks % 5 == 0 )); then
            compose logs --tail 3 panel 2>/dev/null | sed 's/^/    [panel] /' || true
        fi
        sleep 4
    done
    compose logs --tail 40 database || true
    compose logs --tail 40 panel
    die "Panel did not become ready within ~8 minutes (see logs above)."
}

create_admin() {
    local count
    count=$(compose exec -T panel php artisan tinker --no-interaction \
        <<<'echo Pterodactyl\Models\User::count();' 2>/dev/null | grep -oE '[0-9]+' | head -1)
    if [[ "${count:-0}" != "0" ]]; then
        log "Admin user already exists, skipping creation."
        return
    fi
    log "Creating admin user '${ADMIN_USERNAME}'"
    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"
    compose exec -T panel php artisan p:user:make \
        --email="$ADMIN_EMAIL" --username="$ADMIN_USERNAME" \
        --name-first="$ADMIN_FIRSTNAME" --name-last="$ADMIN_LASTNAME" \
        --password="$ADMIN_PASSWORD" --admin=1
}

create_api_key() {
    if existing=$(codespace_env_get APPLICATION_API_KEY 2>/dev/null) && [[ "$existing" == ptla_* ]]; then
        log "Reusing stored Application API key."
        return
    fi
    log "Creating Application API key inside the panel container"
    local key
    key=$(compose exec -T panel php artisan tinker --no-interaction <<'PHP' | grep -oE 'ptla_[A-Za-z0-9]+' | head -1
$admin = Pterodactyl\Models\User::where('root_admin', true)->orderBy('id')->first();
$permissions = [];
foreach (Pterodactyl\Services\Acl\Api\AdminAcl::getResourceList() as $resource) {
    $permissions['r_' . $resource] = Pterodactyl\Services\Acl\Api\AdminAcl::READ | Pterodactyl\Services\Acl\Api\AdminAcl::WRITE;
}
$model = app(Pterodactyl\Services\Api\KeyCreationService::class)
    ->setKeyType(Pterodactyl\Models\ApiKey::TYPE_APPLICATION)
    ->handle(['memo' => 'codespace auto key', 'user_id' => $admin->id], $permissions);
echo $model->identifier . decrypt($model->token), PHP_EOL;
PHP
)
    [[ "$key" == ptla_* ]] || die "failed to create Application API key"
    echo "APPLICATION_API_KEY=${key}" >> "$CODESPACE_ENV"
}

connect_node() {
    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"
    export PANEL_URL="http://127.0.0.1:8080"
    export APPLICATION_API_KEY
    export LOCATION_SHORT="codespace" LOCATION_LONG="GitHub Codespace"
    export NODE_NAME="codespace-node"
    export NODE_FQDN="${CODESPACE_NAME}-8081.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
    export NODE_SCHEME="https" NODE_BEHIND_PROXY="true"
    export NODE_MEMORY=8192 NODE_MEMORY_OVERALLOCATE=0
    export NODE_DISK=20480 NODE_DISK_OVERALLOCATE=0
    export NODE_UPLOAD_LIMIT=100 NODE_DAEMON_PORT=8080 NODE_SFTP_PORT=2022
    export WINGS_DATA_PATH="/var/lib/pterodactyl/volumes"
    export ALLOCATION_IP="$NODE_FQDN" ALLOCATION_PORTS="25565"

    check_api
    ensure_location
    ensure_node
    add_allocations

    log "Rendering Wings config.yml from the panel's /configuration endpoint"
    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"
    api_call GET "/nodes/${NODE_ID}/configuration" \
        | python3 "${SCRIPT_DIR}/render-config.py" "${PTERO_DATA_DIR}/wings/config/config.yml"
    # Direct bridge traffic to sibling containers is dropped in this DinD VM;
    # Wings reaches the panel through the host gateway on the published port.
    sed -i 's|^remote: .*|remote: "http://host.docker.internal:8080"|' "${PTERO_DATA_DIR}/wings/config/config.yml"

    compose up -d wings
}

expose_ports() {
    # Best effort: make forwarded ports public so the browser links work
    # without a GitHub auth prompt. Failure is non-fatal (UI toggle exists).
    if gh codespace ports visibility 8080:public 8081:public 2022:public \
        -c "$CODESPACE_NAME" >/dev/null 2>&1; then
        log "Forwarded ports set to public."
    else
        warn "Could not set ports to public automatically - use the Ports tab."
    fi
}

summary() {
    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"
    cat <<EOF

${C_BOLD}================ Pterodactyl is running in this Codespace ================${C_RESET}
  Panel URL : ${PANEL_PUBLIC_URL}
  Username  : ${ADMIN_USERNAME}
  Password  : ${ADMIN_PASSWORD}
  Wings API : ${WINGS_PUBLIC_URL}  (node: codespace-node)

  Credentials are also stored in: ${CODESPACE_ENV}
  Logs     : bash scripts/codespace-down.sh --logs
  Stop     : bash scripts/codespace-down.sh
  Reset pw : bash scripts/codespace-passwd.sh 'YourNewPassword'
  Add-ons  : bash scripts/codespace-extension.sh list
             bash scripts/codespace-extension.sh theme      (free Darkenate dark theme)
             bash scripts/codespace-extension.sh install <file.blueprint|url>
${C_BOLD}=========================================================================${C_RESET}
EOF
}

main() {
    require_codespace
    command -v docker >/dev/null || die "Docker is not available in this Codespace."

    # Earlier runs under 'sudo su' can leave root-owned bind-mount directories
    # that the unprivileged Codespace user (and containers) cannot write to.
    if [[ -d "$CODESPACE_DIR" ]]; then
        if find "$CODESPACE_DIR" -not -user "$(id -u)" -print -quit 2>/dev/null | grep -q .; then
            warn "Repairing ownership of ${CODESPACE_DIR} (some files were root-owned)"
            sudo chown -R "$(id -u):$(id -g)" "$CODESPACE_DIR"
        fi
    fi

    write_env_file
    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"

    log "Starting database, cache and panel (first run pulls ~1 GB of images)"
    compose up -d database cache
    wait_for_database
    preflight_host_gateway
    compose up -d panel
    wait_for_panel
    create_admin
    create_api_key
    connect_node
    expose_ports
    summary
}

main "$@"
