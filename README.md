# Petro Panel installer

A structured, re-runnable installer for **[Pterodactyl](https://pterodactyl.io/)**
("petro") — the open-source game-server management panel — plus **Wings**, the
daemon that turns a machine into a connected *node*.

It packages the same well-known installation flow used by community "petro"
auto-installers (Panel `v1.11.10` + Wings `v1.13.4`, PHP 8.3, MariaDB, Redis,
Nginx, Docker), split into small, auditable scripts with a single entrypoint.

```
Browser ──HTTPS──> Nginx ──> PHP-FPM ──> Pterodactyl Panel (Laravel)
                                      ├──> MariaDB   (state)
                                      └──> Redis     (cache, sessions, queues)
Panel Application API ──> Wings (node, Docker engine) ──> game-server containers
```

## Requirements

- A fresh **Debian 11/12** or **Ubuntu 20.04 / 22.04 / 24.04** server
- Root / sudo, a public IP, and DNS records for the panel (and node) hostnames
- ≥ 2 GiB RAM and ≥ 15 GiB free disk for the panel; nodes need room for servers
- Outbound HTTPS to `github.com`, `getcomposer.org`, `get.docker.com` and the
  distro package mirrors

## Quick start

```bash
git clone https://github.com/optpic7-droid/panel.git petro && cd petro
cp .env.example .env
nano .env                 # set PANEL_FQDN, admin details, node settings, secrets

sudo ./install.sh preflight          # check the machine is ready
sudo ./install.sh all                # panel + wings + connect node (one machine)
```

Separate machines? Run on the panel server, then on each node server:

```bash
# panel server
sudo ./install.sh panel

# every node server
sudo ./install.sh wings
sudo ./install.sh node               # registers the node over the panel API
```

No arguments gives an interactive menu: `sudo ./install.sh`.

### No shell access? Deploy from GitHub

If you can't (or don't want to) run commands on the VPS directly, the included
**GitHub Actions workflow** installs over SSH from GitHub's runners: store the
VPS host/user/SSH key as repository secrets, then click **Run workflow**.
Full setup: [docs/DEPLOY-GITHUB-ACTIONS.md](docs/DEPLOY-GITHUB-ACTIONS.md).

## What gets installed

| Component | Version | Where |
| --- | --- | --- |
| Pterodactyl Panel | `v1.11.10` (pinned in `.env`) | `/var/www/pterodactyl` |
| Wings | `v1.13.4` (pinned in `.env`) | `/usr/local/bin/wings`, config in `/etc/pterodactyl` |
| PHP | 8.3 (sury.org / ondrej PPA) | distro packages |
| MariaDB, Redis, Nginx | distro packages | systemd services |
| Docker Engine | stable | official `get.docker.com` script |
| Queue worker | `pteroq.service` | systemd |
| TLS (optional) | Let's Encrypt via certbot | when `PANEL_SSL=true` |

Generated passwords are stored in `/root/.petro-panel.env` (mode 600).

## Repository layout

```
install.sh                     entrypoint (menu + subcommands)
.env.example                   all configuration, documented
.github/workflows/deploy.yml   optional GitHub Actions deploy over SSH
scripts/
  lib.sh                       logging, OS detection, API helpers, secrets
  preflight.mjs                zero-dependency Node readiness checker
  10-install-panel.sh          PHP/MariaDB/Redis/Nginx + panel application
  20-install-wings.sh          Docker + Wings daemon + systemd unit
  30-connect-node.sh           creates location/node/allocations via API,
                               runs `wings configure`, starts the node
configs/
  nginx/                       HTTP and HTTPS Nginx site templates
  systemd/                     wings.service and pteroq.service units
  wings/config.yml.example     annotated Wings configuration reference
demo/                          runnable API-compatible preview (random port)
docs/
  INSTALL.md                   full step-by-step install
  DEPLOY-GITHUB-ACTIONS.md     deploy to a VPS without touching its shell
  NODES.md                     connecting and troubleshooting nodes
  TROUBLESHOOTING.md           common failures and fixes
  SANDBOX-NOTES.md             what can/cannot run in restricted environments
tests/smoke.sh                 static validation (bash -n, shellcheck, node --check)
```

## No server available? Try the demos

- **Browser-only (recommended, nothing to install):** open
  [`docs/petro-demo.html`](docs/petro-demo.html) — download the file and
  double-click it. The whole panel (login, nodes, locations, allocations,
  activity log) plus a one-click **node-connect simulation** runs in a single
  browser tab with no server or network. See
  [docs/STANDALONE-DEMO.md](docs/STANDALONE-DEMO.md).
- **Node server:** `node demo/server.mjs` starts the same emulated
  Application API as a real HTTP service on a random port, so the actual
  `scripts/30-connect-node.sh` can register a node against it end-to-end.

Both are demos of the API flow, not the production Pterodactyl binary (which
needs PHP/MariaDB/Redis/Docker and a real VPS).

## Documentation

- **[docs/INSTALL.md](docs/INSTALL.md)** — detailed panel installation
- **[docs/NODES.md](docs/NODES.md)** — nodes, Application API keys, allocations, firewall
- **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — logs, common errors
- **[docs/SANDBOX-NOTES.md](docs/SANDBOX-NOTES.md)** — notes for locked-down CI/sandboxes

## Upgrades

Bump `PANEL_VERSION` / `WINGS_VERSION` in `.env` and re-run the relevant
subcommand; the panel step skips re-download when the installed version marker
matches. Follow the upstream upgrade notes for major versions:
<https://pterodactyl.io/community/about.html>.

## Disclaimer

This project is an unofficial installer and is not affiliated with the
Pterodactyl team. Pterodactyl and Wings are released under their own licenses.
