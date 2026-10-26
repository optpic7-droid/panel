# Deploying to your VPS through GitHub Actions

The repository stores code; it cannot itself run a panel. **GitHub Actions is
the bridge**: a workflow runs on GitHub's servers, opens an SSH connection to
your VPS, copies the installer there and runs it. GitHub runners have full
internet access, so apt, Docker and Composer downloads work even when your
local machine or sandbox is restricted.

The workflow file is [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml).

## How it works

```
GitHub Actions runner ──SSH (port 22)──> your VPS
  1. validates the required secrets
  2. renders a .env from workflow inputs + repository secrets
  3. copies the installer to /opt/petro (SCP)
  4. runs:  sudo ./install.sh <mode>
```

Nothing runs until you press **Run workflow** — there are no automatic
deployments on push.

## One-time setup

### 1. Prepare the VPS

- Fresh Debian 11/12 or Ubuntu 20.04/22.04/24.04, reachable on TCP port 22.
- A user with passwordless `sudo` (root is fine).
- DNS `A` record for the panel domain pointing at the VPS public IP
  (and for the node domain, if separate).
- Firewall allows SSH from GitHub's runners. Simplest: keep port 22 open to
  the world with key-only auth; stricter option is allowing
  [GitHub's Actions IP ranges](https://api.github.com/meta) (`actions` key).

### 2. Create an SSH deploy key (on your own machine)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/petro_deploy -N ""
ssh-copy-id -i ~/.ssh/petro_deploy.pub root@YOUR_VPS_IP
# verify: ssh -i ~/.ssh/petro_deploy root@YOUR_VPS_IP 'echo ok'
```

### 3. Store the connection details as repository secrets

GitHub repo page → **Settings → Secrets and variables → Actions → New
repository secret**. Add:

| Secret | Required | Example |
| --- | --- | --- |
| `VPS_HOST` | yes | `203.0.113.10` or `vps.example.com` |
| `VPS_USER` | yes | `root` |
| `VPS_SSH_KEY` | yes | full contents of `~/.ssh/petro_deploy` (the **private** key, `-----BEGIN OPENSSH PRIVATE KEY-----` …) |
| `VPS_ADMIN_EMAIL` | yes | `you@example.com` — panel admin login |
| `VPS_SSH_PORT` | no | only if SSH is not on port 22 |
| `VPS_ADMIN_USERNAME` | no | defaults to `admin` |
| `LETSENCRYPT_EMAIL` | no | defaults to `VPS_ADMIN_EMAIL` |
| `PANEL_URL` | no | only for `node` mode against an existing panel |
| `APPLICATION_API_KEY` | no | `ptla_...` key, only for `node` mode |

Equivalent with the GitHub CLI (run on your own machine; the key never goes
through chat or the repository itself):

```bash
gh secret set VPS_HOST        --body "203.0.113.10" --repo optpic7-droid/panel
gh secret set VPS_USER        --body "root"           --repo optpic7-droid/panel
gh secret set VPS_SSH_KEY     < ~/.ssh/petro_deploy   --repo optpic7-droid/panel
gh secret set VPS_ADMIN_EMAIL --body "you@example.com" --repo optpic7-droid/panel
```

### 4. Run the workflow

**Actions tab → Deploy Petro Panel → Run workflow**, then fill:

- **mode** — `all` (panel + wings + connect on one VPS), `panel`, `wings`, or `node`
- **panel_fqdn** — e.g. `panel.example.com`
- **panel_ssl** — keep ticked if the domain's DNS already points at the VPS
- **node_fqdn** — VPS hostname/IP (required for `all`, `wings`, `node`)
- **allocation_ip** — defaults to `node_fqdn`
- **allocation_ports** — default `25565,25570-25575`
- **remote_dir** — default `/opt/petro`

Watch the live log; a full run typically takes 10–25 minutes (package installs,
Composer, Docker, migrations).

## After the run

- Panel URL: `https://<panel_fqdn>` (or `http://` with SSL off).
- The admin password and database password are generated on the VPS and stored
  in `/root/.petro-panel.env` (mode 600). The workflow prints the key names but
  never the secret values. Read them on the VPS:
  `sudo cat /root/.petro-panel.env`.
- Re-running the workflow is safe: existing databases, admin users, locations
  and nodes are reused, not duplicated.

## Security notes

- Repository secrets are encrypted by GitHub and only exposed to the running
  workflow; anyone with repo admin access can run a deploy — grant admin
  carefully.
- Prefer a dedicated deploy key (step 2), not your personal SSH key, so access
  can be revoked by deleting one line in the VPS `authorized_keys`.
- Workflow logs can contain hostnames and package output; they do not contain
  the secret values (GitHub masks them).
- If the VPS provider supports it, restrict the deploy key further with a
  `command=` entry in `authorized_keys`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Missing required repository secrets` | Add every secret marked "yes" in the table above. |
| SSH handshake / timeout | Check `VPS_HOST`, `VPS_SSH_PORT`, firewall rules and that the public key is in `authorized_keys`. |
| `Permission denied (publickey)` | The private key in `VPS_SSH_KEY` does not match an authorized public key. Verify with a manual SSH login. |
| Certbot step skipped | DNS for `panel_fqdn` does not resolve to this VPS yet, or port 80 is closed. Re-run after fixing DNS. |
| Node shows no heartbeat | Open 8080/tcp and 2022/tcp on the VPS firewall; see [NODES.md](NODES.md). |
| Actions tab missing | A repo owner must enable GitHub Actions in **Settings → Actions → General**. |

Manual installation without Actions remains the simpler path for a single
VPS — see [INSTALL.md](INSTALL.md).
