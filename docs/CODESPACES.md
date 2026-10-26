# Real Pterodactyl inside GitHub Codespaces

No VPS? The repo can run the **genuine Pterodactyl application** (not the
browser mock) inside a GitHub Codespace, using the official container images
`ghcr.io/pterodactyl/panel` and `ghcr.io/pterodactyl/wings` plus MariaDB and
Redis. A Codespace is a full Linux VM with Docker built in.

## Start (one command)

1. On the repo page: **Code → Codespaces → Create codespace on
   `arena/bdb8cdd2-panel`** (or on `main` after PR #1 is merged).
2. Wait for the terminal, then run:

   ```bash
   bash scripts/codespace-up.sh
   ```

   The first run pulls ~1 GB of images and takes 5–10 minutes. The script:

   - writes secrets/URLs to `.codespace/.env` (git-ignored)
   - starts MariaDB, Redis and the official panel container; its entrypoint
     runs `migrate --seed` automatically
   - creates an admin user and a full-permission `ptla_` API key
   - registers a node, renders `config.yml` from the panel's
     `/configuration` endpoint and starts Wings (privileged, docker.sock)
   - makes the forwarded ports public and prints the panel URL + password

3. Open the printed **Panel URL**
   (`https://<codespace>-8080.<domain>`) and log in. This is the real
   Pterodactyl UI — admin area, nests, eggs, databases, schedules, the node
   with a live heartbeat, everything.

Stop / resume / reset:

```bash
bash scripts/codespace-down.sh           # stop, keep all data
bash scripts/codespace-up.sh             # resume (idempotent)
bash scripts/codespace-down.sh --purge   # delete everything and start fresh
```

## Ports

| Host port | Container | Purpose |
| --- | --- | --- |
| 8080 | panel:80 | Panel web UI / API |
| 8081 | wings:8080 | Wings API + websocket |
| 2022 | wings:2022 | SFTP |
| 25565 | wings:25565 | Example allocation (TCP) |

If a port opens with an auth prompt, use the **Ports** tab in VS Code →
right-click → **Port Visibility → Public** (the script attempts this itself
via `gh`).

Ports 3306 (MariaDB) and 6379 (Redis) are published on the Docker VM as well,
but only for internal container-to-container use: in the Codespaces
Docker-in-Docker VM the bridge drops traffic between sibling containers, so
the panel and Wings reach their dependencies through `host.docker.internal`
(the host gateway) against those published ports, instead of service names.

## Themes and extensions (Blueprint)

The panel runs the official **Blueprint framework** image
(`ghcr.io/blueprintframework/blueprint`, built from the matching Pterodactyl
panel image) — Pterodactyl's open-source extension engine. Themes, version
changers and plugin managers are all installed as `.blueprint` archives:

```bash
bash scripts/codespace-extension.sh list                       # installed add-ons
bash scripts/codespace-extension.sh theme                      # free Darkenate dark theme (MIT)
bash scripts/codespace-extension.sh install ./Arix.blueprint   # a licensed add-on you own
bash scripts/codespace-extension.sh install https://example.test/x.blueprint
bash scripts/codespace-extension.sh remove Darkenate
```

Archives are kept in `.codespace/data/extensions` (mounted at
`/blueprint_extensions`) and the framework's listener syncs them into the
panel; a named Docker volume preserves installed extension code across
restarts.

**Arix** is commercial software (arix.gg / BuiltByBit). Buy it, download the
`.blueprint` file, and install it with the `install` command above. This repo
never downloads nulled/leaked add-ons — they are a common source of stolen
API keys and backdoors. A "version changer / plugin installer" for
Pterodactyl 1.x is likewise just another `.blueprint` from the Blueprint
marketplace; the v2-only `.pteroext` format is not compatible with this stack.

## Admin password

```bash
bash scripts/codespace-passwd.sh                 # random new password
bash scripts/codespace-passwd.sh 'MyNewPass123'  # chosen password
```

The value is updated inside the panel and persisted to `.codespace/.env`.

## Honest limitations

- **Not 24/7.** Codespaces auto-stop after ~30 minutes idle and, on GitHub
  Free, include 120 core-hours per month (≈60 h on a 2-core machine).
  Stopping does not delete data; deleting the codespace does.
- **Not a game-host.** The panel and Wings work fully, and the node's
  heartbeat is green, but the Codespace proxy is meant for HTTP/TCP
  development traffic — UDP game ports and large player audiences are not
  supported. For real hosting use a VPS (`./install.sh all`), e.g. Oracle
  Cloud's always-free ARM VM.
- **Backups.** `.codespace/data` holds the database and server volumes.
  Download it from the explorer or commit nothing (it is git-ignored).

## How it differs from the browser demo

`docs/petro-demo.html` is a zero-backend mock of the API flow. The Codespace
stack runs the actual Pterodactyl v1.11.x code, the real MariaDB schema and
the real Wings daemon — the only difference from a VPS install is the
containerized, time-limited environment.
