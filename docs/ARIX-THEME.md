# Installing the Arix theme

[**Arix**](https://arix.gg/pterodactyl-theme) is the most popular commercial
theme for Pterodactyl (a dark, crimson-accented UI with a page builder and
addons). It is **paid, proprietary software** sold on arix.gg and BuiltByBit.
This repository does not ship Arix files and will not download "nulled"
copies — leaked theme packages are a common source of panel backdoors and
stolen API keys.

## What the installer does

`scripts/40-theme-arix.sh` (also `./install.sh theme`) performs the official
installation procedure against **your licensed archive**:

1. Validates the zip (must contain a Pterodactyl-style `artisan` file and
   `resources/scripts/` tree; rejects path-traversal entries).
2. Writes a timestamped code backup under
   `/var/www/pterodactyl-backups/` (user data in `storage/` is untouched).
3. Extracts and copies the theme files into `/var/www/pterodactyl`.
4. `composer install` → `php artisan migrate --force`.
5. Installs Arix's extra frontend packages with yarn and runs
   `NODE_OPTIONS=--openssl-legacy-provider yarn build:production`.
6. Runs `php artisan arix install` when the theme registers that command.
7. Rebuilds caches (`optimize:clear` / `optimize`) and fixes www-data
   permissions.

## Prerequisites

- A panel already installed with `./install.sh panel` (v1.11.x — Arix supports
  Pterodactyl 1.11/1.12).
- Node.js + yarn on the panel host (the panel build step already needs them;
  Arix documents Node 18/20/22 support).
- Your licensed Arix zip, uploaded to the VPS (e.g. `/root/arix-theme.zip`).

## Install

```bash
# Option A: archive already on the server
sudo ARIX_ZIP=/root/arix-theme.zip ./install.sh theme

# Option B: signed download URL from your arix.gg/BuiltByBit account
sudo ARIX_SOURCE_URL="https://example.test/arix?token=..." ./install.sh theme
```

Or set `ARIX_ZIP` / `ARIX_SOURCE_URL` in `.env` and run `sudo ./install.sh theme`.

Arix releases occasionally change their extra npm dependency list. Override
the default with `ARIX_EXTRA_PACKAGES="pkg1 pkg2"` if a specific release's
readme asks for it.

## Uninstall / roll back

Every install creates a backup, so the stock panel is one command away:

```bash
sudo ./install.sh theme --uninstall
```

This restores the newest backup, rebuilds the frontend and caches, and
returns the panel to its pre-Arix state.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `No Arix archive configured` | Set `ARIX_ZIP` to the uploaded file or `ARIX_SOURCE_URL` to a licensed download. |
| `archive validation failed` | The zip isn't a Pterodactyl/Arix package (or contains `..` paths). Re-download from your account. |
| Build fails with OpenSSL/hash errors | The script already passes `--openssl-legacy-provider`; ensure Node is 18/20/22, not 16 or older. |
| White screen after install | `cd /var/www/pterodactyl && php artisan optimize:clear && php artisan optimize`, then hard-refresh the browser. |
| Permission errors | `chown -R www-data:www-data /var/www/pterodactyl && chmod -R 755 storage bootstrap/cache` |
| Want the official vendor docs | Visit <https://arix.gg/docs> (full installation guide is behind license login). |

## About the "Arix-inspired" demo skin

`docs/petro-demo.html` (and the demo server at `/`) use an original
Arix-*inspired* look — near-black canvas, crimson gradient accents, glassy
cards. It contains **no Arix code or assets**; it only demonstrates the panel
and node-connection flow in a similar visual style. The real Arix theme is
installed exclusively through the licensed flow above.
