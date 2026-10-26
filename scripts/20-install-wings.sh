#!/usr/bin/env bash
# =============================================================================
# scripts/20-install-wings.sh
# Installs Docker and the Wings daemon (a Pterodactyl "node") and registers
# its systemd service. The node is not started until a config.yml exists -
# run scripts/30-connect-node.sh (or the panel's auto-deploy) to create one.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

main() {
    load_config
    require_root
    detect_os
    install_docker
    install_wings
    install_service

    log "Wings ${WINGS_VERSION} installed."
    if [[ -f "${WINGS_CONFIG_PATH}/config.yml" ]]; then
        log "Existing configuration found - starting Wings."
        systemctl restart wings
    else
        warn "No ${WINGS_CONFIG_PATH}/config.yml yet."
        warn "Create the node in the panel, then run: sudo ./install.sh node"
        warn "(or scripts/30-connect-node.sh) to connect this machine."
    fi
}

install_docker() {
    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        log "Docker is already installed and running."
        return
    fi

    log "Installing Docker Engine via get.docker.com"
    curl -fsSL https://get.docker.com | CHANNEL=stable sh
    systemctl enable --now docker
    docker info >/dev/null 2>&1 || die "Docker was installed but the daemon is not running."
}

install_wings() {
    local arch
    case "$(uname -m)" in
        x86_64)  arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) die "Unsupported architecture: $(uname -m) (Wings ships amd64/arm64 only)." ;;
    esac

    mkdir -p "$WINGS_CONFIG_PATH" "$WINGS_DATA_PATH"

    if [[ -x /usr/local/bin/wings ]] && /usr/local/bin/wings version 2>/dev/null | grep -q "${WINGS_VERSION#v}"; then
        log "Wings ${WINGS_VERSION} already installed."
        return
    fi

    log "Downloading Wings ${WINGS_VERSION} (${arch})"
    curl -fL --retry 3 -o /usr/local/bin/wings \
        "https://github.com/pterodactyl/wings/releases/download/${WINGS_VERSION}/wings_linux_${arch}"
    chmod u+x /usr/local/bin/wings
    /usr/local/bin/wings version
}

install_service() {
    log "Installing systemd unit /etc/systemd/system/wings.service"
    cp "${PETRO_ROOT}/configs/systemd/wings.service" /etc/systemd/system/wings.service
    systemctl daemon-reload
    systemctl enable wings
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
