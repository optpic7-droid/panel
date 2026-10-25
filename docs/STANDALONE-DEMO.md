# Standalone demo — no server, no sandbox, no network

[`docs/petro-demo.html`](../docs/petro-demo.html) is the entire Petro Panel
demo packed into **one HTML file**. It runs entirely inside a browser tab:

- no server process, no open ports, no internet needed after download
- emulates the same Pterodactyl Application API contract
  (`/api/application/locations`, `/nodes`, `/nodes/:id/allocations`,
  `/nodes/:id/configuration`) used by `scripts/30-connect-node.sh`
- a **Run node-connect simulation** button performs the full connector
  sequence live, flips the node to connected, and downloads the generated
  `config.yml`
- state persists in `localStorage`; "Reset demo data" clears it

## How to open it

### Option A — open the file directly (works immediately)

1. Open
   <https://github.com/optpic7-droid/panel/blob/arena/bdb8cdd2-panel/docs/petro-demo.html>
2. Click the **Download raw file** button (top-right of the file view).
3. Double-click the downloaded `petro-demo.html` — it opens in any browser,
   even offline. Login is pre-filled: `admin` / `petro-demo`.

### Option B — permanent URL with GitHub Pages (after merging PR #1)

1. Merge the PR, then open the repo's **Settings → Pages**.
2. Under **Build and deployment → Source**, choose **Deploy from a branch**.
3. Branch: `main`, folder: `/docs`, then **Save**.
4. Wait ~1 minute; the demo is then permanently available at:

   ```
   https://optpic7-droid.github.io/panel/petro-demo.html
   ```

   (The repository token used by the installer cannot toggle Pages itself —
   GitHub requires a repo owner to do this one-time switch.)

## What the simulation shows

Each step mirrors one request the real connector sends:

| Step | Equivalent in `scripts/30-connect-node.sh` |
| --- | --- |
| `GET /nodes` | `check_api` — verifies the `ptla_` key |
| `POST /locations` | `ensure_location` |
| `POST /nodes` | `ensure_node` (same JSON fields and types) |
| `POST /nodes/:id/allocations` | `add_allocations` (ports 25565, 25570–25572) |
| `GET /nodes/:id/configuration` | `write_wings_config` — produces `config.yml` |

The downloadable `config.yml` has the identical YAML shape that Wings expects
and that `scripts/render-config.py` writes on a real node.

This is a demonstration of the API flow and UI, not the production Pterodactyl
binary — that requires PHP, MariaDB, Redis and Docker and runs on a VPS via
`install.sh` (or the GitHub Actions deploy workflow).
