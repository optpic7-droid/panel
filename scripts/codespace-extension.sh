#!/usr/bin/env bash
# =============================================================================
# scripts/codespace-extension.sh
# Manage Blueprint extensions (.blueprint add-ons/themes) on the Codespace
# panel. Blueprint is the official open extension framework for Pterodactyl:
# Arix, version changers, themes and plugin managers are all installed the
# same way. This script never downloads nulled/leaked add-ons - supply a
# licensed file/URL or use the curated free 'theme' command.
#
# Usage:
#   bash scripts/codespace-extension.sh list
#   bash scripts/codespace-extension.sh theme                  # free Darkenate dark theme (MIT)
#   bash scripts/codespace-extension.sh install <file.blueprint|https://.../x.blueprint>
#   bash scripts/codespace-extension.sh remove <identifier>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/codespace-common.sh"

# Read the Blueprint identifier from a .blueprint zip (conf.yml inside).
# Real-world archives nest the field under 'info:' (e.g. Darkenate), so match
# an indented key and stay dependency-free (no PyYAML needed at runtime).
extension_identifier() {
    local file=$1
    python3 - "$file" <<'PY'
import sys, zipfile, re
path = sys.argv[1]
try:
    with zipfile.ZipFile(path) as z:
        conf = next((n for n in z.namelist() if n.endswith("conf.yml")), None)
        if not conf:
            sys.exit("no conf.yml inside archive")
        text = z.read(conf).decode("utf-8", "replace")
except (OSError, zipfile.BadZipFile) as exc:
    sys.exit(f"not a valid .blueprint archive: {exc}")
m = re.search(r"^\s*identifier:\s*['\"]?([A-Za-z0-9_\-]+)['\"]?\s*$", text, re.M)
if not m:
    sys.exit("conf.yml has no 'identifier' field")
print(m.group(1))
PY
}

# Read the Blueprint framework version an extension targets, for logging.
extension_target() {
    local file=$1
    python3 - "$file" <<'PY'
import sys, zipfile, re
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        conf = next((n for n in z.namelist() if n.endswith("conf.yml")), None)
        text = z.read(conf).decode("utf-8", "replace") if conf else ""
except (OSError, zipfile.BadZipFile):
    sys.exit(1)
m = re.search(r"^\s*target:\s*['\"]?([^'\"\s]+)", text, re.M)
print(m.group(1) if m else "unspecified")
PY
}

extension_dir() {
    # shellcheck disable=SC1090
    source "$CODESPACE_ENV"
    echo "${PTERO_DATA_DIR}/extensions"
}

install_extension() {
    local source=$1 dir file ident
    [[ -n "$source" ]] || die "usage: codespace-extension.sh install <file.blueprint|url>"
    dir=$(extension_dir)
    mkdir -p "$dir"

    if [[ "$source" == http://* || "$source" == https://* ]]; then
        local name
        name=$(basename "${source%%\?*}")
        [[ "$name" == *.blueprint ]] || die "URL must point at a .blueprint file"
        file="${dir}/${name}"
        log "Downloading ${source}"
        curl -fL --retry 2 -o "$file" "$source" || die "download failed"
    else
        [[ -f "$source" ]] || die "file not found: $source"
        [[ "$source" == *.blueprint ]] || die "only .blueprint archives are supported"
        file="${dir}/$(basename "$source")"
        cp -f "$source" "$file"
    fi

    ident=$(extension_identifier "$file") || die "$ident"
    log "Extension identifier: ${ident} (target: $(extension_target "$file" 2>/dev/null || echo unknown))"

    # The image's inotify listener also syncs this folder, but copying
    # directly makes installation deterministic and immediate.
    compose cp "$file" "panel:/app/$(basename "$file")"
    log "Installing '${ident}' with Blueprint (frontend rebuild can take a few minutes)"
    compose exec -T panel blueprint -install "$ident"
    log "Installed. Hard-refresh the browser (Ctrl+Shift+R) to see changes."
    log "Archive kept in ${file} for re-installation after container rebuilds."
}

remove_extension() {
    local ident=$1
    [[ -n "$ident" ]] || die "usage: codespace-extension.sh remove <identifier>"
    log "Removing '${ident}' with Blueprint"
    compose exec -T panel blueprint -remove "$ident" || die "blueprint remove failed"
    local dir
    dir=$(extension_dir)
    rm -f "${dir}/${ident}.blueprint"
    compose exec -T panel rm -f "/app/${ident}.blueprint" 2>/dev/null || true
    log "Removed ${ident}."
}

install_darkenate() {
    # Curated free option: Darkenate, MIT-licensed, maintained in the official
    # blueprint-community GitHub organisation. No paid or nulled content.
    local url
    url=$(curl -fsS https://api.github.com/repos/blueprint-community/extension-darkenate/releases/latest \
        | python3 -c "import json,sys; print(next(a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].endswith('.blueprint')))") \
        || die "could not resolve the latest Darkenate release from GitHub"
    log "Installing free Darkenate dark theme (MIT)"
    install_extension "$url"
}

usage() {
    cat <<'EOF'
Blueprint extension manager for the Codespace panel:
  list                          list installed extensions
  theme                         install the free Darkenate dark theme (MIT)
  install <file|url>            install any licensed .blueprint (Arix, etc.)
  remove <identifier>           uninstall an extension
EOF
}

main() {
    require_codespace
    [[ -f "$CODESPACE_ENV" ]] || die "Run bash scripts/codespace-up.sh first."
    local cmd=${1:-}
    case "$cmd" in
        list)
            compose exec -T panel blueprint -list ;;
        theme)
            install_darkenate ;;
        install)
            shift; install_extension "${1:-}" ;;
        remove|uninstall)
            shift; remove_extension "${1:-}" ;;
        ""|-h|--help|help)
            usage ;;
        *)
            usage; die "unknown command: $cmd" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
