# Connecting a node (Wings)

A *node* is a machine running **Wings** and **Docker**. The panel tells Wings
what servers to run; Wings creates their containers and reports back over the
Application API and a websocket.

## Topology

- **Same machine as the panel:** run `sudo ./install.sh all`, or the two
  subcommands `wings` then `node`.
- **Separate machine:** copy this repository (or just your `.env`) to the node
  server, set `PANEL_URL` and `APPLICATION_API_KEY`, then:

  ```bash
  sudo ./install.sh wings     # Docker + Wings binary + systemd unit
  sudo ./install.sh node      # register node, allocations, write config.yml
  ```

## 1. Create an Application API key on the panel

**Automatic (recommended):** `sudo ./install.sh apikey` creates a
full-permission key via tinker, prints it once and stores it in
`/root/.petro-panel.env`. The `./install.sh all` flow runs this step itself,
so all-in-one installs need no manual key handling.

**Manual alternative:**

1. Log in as administrator → **Admin → Application API → Create New Key**.
2. Description: `node-connector`.
3. Permissions: **write** on `Locations`, `Nodes`, `Allocations` (read on the
   rest is fine).
4. Copy the token — it starts with `ptla_` — into `.env`:

   ```dotenv
   PANEL_URL="https://panel.example.com"
   APPLICATION_API_KEY="ptla_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
   ```

## 2. Node settings in `.env`

```dotenv
LOCATION_SHORT="loc1"            # created automatically if missing
NODE_NAME="node-1"
NODE_FQDN="node.example.com"     # public hostname or IP of THIS machine
NODE_SCHEME="https"              # http behind a plain network, https with TLS
NODE_BEHIND_PROXY="false"        # true if a proxy terminates TLS for Wings
NODE_MEMORY="8192"               # MiB, 0 = unlimited
NODE_DISK="20480"
NODE_DAEMON_PORT="8080"          # Wings API / websocket
NODE_SFTP_PORT="2022"
ALLOCATION_IP="node.example.com" # IP game servers bind to
ALLOCATION_PORTS="25565,25570-25575,27015"
```

## 3. What `scripts/30-connect-node.sh` does

1. `GET /api/application/nodes` — verifies the panel URL and API key.
2. Finds or creates the **location** (`POST /locations`).
3. Finds or creates the **node** (`POST /nodes`) with memory/disk limits,
   daemon ports and SFTP settings.
4. Adds **allocations** (`POST /nodes/{id}/allocations`), expanding ranges like
   `25570-25575` into individual ports.
5. Runs `wings configure --panel-url … --token ptla_… --node <id> --override`,
   which calls `GET /nodes/{id}/configuration` and writes
   `/etc/pterodactyl/config.yml` (chmod 600). If the Wings binary is absent it
   writes the same file directly from the API response.
6. Enables and starts `wings.service` and prints the node record. The panel's
   heartbeat indicator turns green within ~10 seconds.

### Manual equivalent

Panel UI: **Admin → Nodes → Create New**, then the **Configuration** tab shows
the token. On the node:

```bash
mkdir -p /etc/pterodactyl
wings configure --panel-url https://panel.example.com --token ptla_xxx --node 1
systemctl enable --now wings
```

## 4. Firewall and DNS

On every node, allow:

| Port | Purpose |
| --- | --- |
| 8080/tcp | Wings API + websocket (browsers and the panel reach this) |
| 2022/tcp | SFTP for server file access |
| allocation ports | game server ports, e.g. 25565/tcp+udp |

```bash
ufw allow 8080/tcp && ufw allow 2022/tcp
ufw allow 25565:25575/tcp && ufw allow 25565:25575/udp
```

`NODE_FQDN` must resolve to the node's public IP (or use a plain IP with
`NODE_SCHEME=http` for testing). For HTTPS, terminate TLS with certbot/Nginx or
set `NODE_BEHIND_PROXY=true` when a proxy handles the certificate.

## 5. Verify

```bash
systemctl status wings --no-pager
wings diagnostics                 # built-in self-test
curl -sS -H "Authorization: Bearer $APPLICATION_API_KEY" \
     -H "Accept: application/json" \
     "$PANEL_URL/api/application/nodes/$NODE_ID" | python3 -m json.tool
```

In the panel, **Admin → Nodes → node-1** shows a green heartbeat and the
configured allocations. You can now create a server on the node.

## Adding more nodes

Copy the repo to each additional machine, give it a unique `NODE_NAME` /
`NODE_FQDN`, keep the same `PANEL_URL` and API key, and run
`sudo ./install.sh wings && sudo ./install.sh node`. Locations are reused by
their `LOCATION_SHORT` code.
