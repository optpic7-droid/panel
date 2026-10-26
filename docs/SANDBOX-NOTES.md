# Running in restricted sandboxes / CI

The installer targets a normal root VPS with full internet access. Locked-down
environments (some CI sandboxes, air-gapped labs) only allow a few hosts and
ship without PHP, Docker or a package mirror. This document records what can be
validated there and what cannot, and how this repository was verified.

## What a full install needs

| Dependency | Delivered by | Why it is required |
| --- | --- | --- |
| PHP 8.3 + extensions | distro apt repository + sury/ondrej | runs the Laravel panel |
| MariaDB | distro apt repository | panel state (MySQL-specific schema) |
| Redis | distro apt repository | cache, sessions, queues |
| Nginx | distro apt repository | web server / PHP-FPM proxy |
| Composer | `getcomposer.org` | PHP dependency installation |
| Panel release tarball | GitHub release assets | application code incl. `vendor/` |
| Docker Engine | `get.docker.com` + download mirror | Wings only runs servers as containers |
| Wings binary | GitHub release assets | node daemon |

## Observed egress restrictions (example sandbox)

During development, only these hosts were reachable:

```
github.com, api.github.com, codeload.github.com, registry.npmjs.org, pypi.org
```

Blocked (connection reset at TLS): `deb.debian.org`, `getcomposer.org`,
`packagist.org`, `get.docker.com`, `registry-1.docker.io`, `ghcr.io`,
`raw.githubusercontent.com`, and the GitHub release-asset hosts
(`objects.githubusercontent.com`, `release-assets.githubusercontent.com`).
There was also no Docker daemon and no running systemd PID 1.

Consequences:

- `apt-get install` cannot fetch PHP/MariaDB/Redis/Nginx → the panel cannot
  boot in such an environment.
- Composer/Packagist and release-asset downloads are blocked → no `vendor/`.
- Docker cannot be installed → Wings can be configured but cannot start
  containers, which is its core function.

**The scripts therefore must be executed on a real Debian/Ubuntu server (or a
VM/container with full network and a Docker daemon), not in a restricted
sandbox.**

## What IS verifiable without the full stack

Everything below runs with no root and no apt access, and is wired into
`tests/smoke.sh`:

1. **Shell syntax** — `bash -n` on every script.
2. **Linting** — [shellcheck](https://www.shellcheck.net/)
   (`pip install --user shellcheck-py` works when PyPI is reachable).
3. **Node syntax** — `node --check scripts/preflight.mjs`, plus a live run of
   the preflight checker itself.
4. **Upstream source integrity** — the pinned tags clone from GitHub over
   `git`/`codeload`:
   ```bash
   git clone --depth 1 --branch v1.11.10 https://github.com/pterodactyl/panel
   git clone --depth 1 --branch v1.13.4  https://github.com/pterodactyl/wings
   ```
5. **Panel frontend production build** — the one part of the panel that needs
   only Node. With the npm registry reachable:
   ```bash
   cd panel
   # If yarn.lock points at registry.yarnpkg.com, repoint it at the allowed mirror:
   sed -i 's|https://registry.yarnpkg.com|https://registry.npmjs.org|g' yarn.lock
   yarn install --frozen-lockfile
   NODE_ENV=production NODE_OPTIONS=--openssl-legacy-provider \
       ./node_modules/.bin/webpack
   # hashed, production assets land in public/assets/
   ```
   The `--openssl-legacy-provider` flag is required on Node 17+ because the
   v1.11 webpack toolchain uses the removed MD4 hash by default.
6. **API contract review** — the node connector's payloads were written from
   the v1.11.10 source itself:
   - `routes/api-application.php` (nodes, allocations, locations endpoints)
   - `app/Http/Requests/Api/Application/Nodes/StoreNodeRequest.php` (fields)
   - `app/Models/Node.php` (`getConfiguration()` shape used for `config.yml`)
   - Wings `cmd/configure.go` (`wings configure` calls
     `GET /api/application/nodes/{id}/configuration` with the `ptla_` key).

## Adapting to an internal mirror

On an air-gapped network, point the installer at internal mirrors by
pre-installing the packages and overriding the download URLs in
`scripts/10-install-panel.sh` and `scripts/20-install-wings.sh` (they are plain
`curl` lines at the top of each download function), or mirror:

- the Pterodactyl `panel.tar.gz` and `wings_linux_*` release assets,
- the Composer phar and a Packagist mirror,
- a Docker registry with the required game-server images.
