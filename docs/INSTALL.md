# Panel installation guide

This guide explains exactly what `sudo ./install.sh panel` does, so you can
run it end-to-end or reproduce every step manually.

## 1. Prepare the server

1. Fresh Debian 11/12 or Ubuntu 20.04/22.04/24.04, updated and rebooted.
2. DNS `A` record for `PANEL_FQDN` pointing at the server's public IP.
3. Open inbound ports: `80`, `443` (panel), and later `8080` + `2022` if Wings
   runs on the same machine.

```bash
git clone https://github.com/optpic7-droid/panel.git petro
cd petro
cp .env.example .env
chmod 600 .env
nano .env
```

Required values for the panel: `PANEL_FQDN`, `PANEL_SSL`, `LETSENCRYPT_EMAIL`,
`ADMIN_*`. Leave `DB_PASSWORD` / `ADMIN_PASSWORD` empty to auto-generate them
(they are written to `/root/.petro-panel.env`).

Run the readiness check:

```bash
sudo ./install.sh preflight
```

## 2. What the installer does (`scripts/10-install-panel.sh`)

1. **Packages** — installs base tooling, then adds the PHP 8.3 repository
   (`packages.sury.org` on Debian, `ppa:ondrej/php` on Ubuntu) and installs
   `php8.3` with `cli, gd, mysql, mbstring, bcmath, xml, fpm, curl, zip, intl`,
   plus `mariadb-server`, `nginx`, `redis-server`, `certbot`.
2. **Database** — connects over the local root socket and creates the
   `panel` database and the `pterodactyl` user with a generated password.
3. **Panel files** — downloads the pinned
   `panel.tar.gz` from GitHub releases into `/var/www/pterodactyl` and installs
   Composer 2 if missing.
4. **Application setup** — `composer install`, `artisan key:generate`,
   `p:environment:setup` (Redis for cache/session/queue),
   `p:environment:database`, then `migrate --seed --force`.
5. **Admin user** — non-interactive `p:user:make --admin=1` (skipped if the
   email already exists, so re-runs are safe).
6. **Web server** — renders `configs/nginx/*.conf` with the FQDN and the PHP-FPM
   socket path, enables the site, validates with `nginx -t`.
7. **Background work** — installs the `pteroq` queue worker and a
   `/etc/cron.d/pterodactyl` scheduler entry.
8. **TLS** — when `PANEL_SSL=true`, requests a Let's Encrypt certificate and
   configures the HTTP→HTTPS redirect.
9. Caches the Laravel config and prints the login URL and credentials.

## 3. Manual equivalent (reference)

```bash
# Packages (Debian 12 example)
apt update
apt install -y ca-certificates curl apt-transport-https gnupg lsb-release \
               software-properties-common unzip tar git cron
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php-sury-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/php-sury-keyring.gpg] https://packages.sury.org/php/ bookworm main" \
  > /etc/apt/sources.list.d/php-sury.list
apt update
apt install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl} \
               mariadb-server nginx redis-server

# Database
mysql -e "CREATE DATABASE panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
          CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY 'CHANGE_ME';
          GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
          FLUSH PRIVILEGES;"

# Application
mkdir -p /var/www/pterodactyl && cd /var/www/pterodactyl
curl -fL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/download/v1.11.10/panel.tar.gz
tar -xzf panel.tar.gz && chmod -R 755 storage/* bootstrap/cache/
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
cp .env.example .env
composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan p:environment:setup --url=https://panel.example.com --cache=redis \
    --session=redis --queue=redis --redis-host=127.0.0.1 --redis-pass="" --telemetry=false
php artisan p:environment:database --host=127.0.0.1 --database=panel \
    --username=pterodactyl --password=CHANGE_ME
php artisan migrate --seed --force
php artisan p:user:make --admin=1
chown -R www-data:www-data /var/www/pterodactyl
```

Then install the Nginx site from `configs/nginx/`, the queue worker from
`configs/systemd/pteroq.service`, and the scheduler cron (the script does all
three automatically).

## 4. First login

Browse to `https://PANEL_FQDN`, sign in with the admin account, then:

1. **Admin → Locations** — confirm the location the node script will reuse.
2. **Admin → Application API** — create a key with read/write on *Locations*,
   *Nodes* and *Allocations*; copy the `ptla_...` value into `.env`
   (`APPLICATION_API_KEY`) for the node step.
3. Continue with [NODES.md](NODES.md).

## Running without a domain (custom port / bare IP)

Set in `.env`:

```dotenv
PANEL_FQDN="203.0.113.10"   # or a hostname
PANEL_PORT="8088"           # any free port instead of 80
PANEL_SSL="false"           # Let's Encrypt needs port 80 + a real domain
```

The installer renders `listen 8088;` into the Nginx site and sets the panel's
`APP_URL` to `http://203.0.113.10:8088` automatically (the `panel_url` helper
hides standard ports 80/443 and appends every other port). Open the chosen
port in the firewall: `ufw allow 8088/tcp`. The node side already supports
custom daemon ports via `NODE_DAEMON_PORT` (default 8080).

## Trying it without a server at all

`demo/server.mjs` is a zero-dependency Node server that emulates the
Application API and serves a small dashboard, so the full node-connection flow
can be exercised on any machine (or in a locked-down sandbox):

```bash
node demo/server.mjs           # picks a random port, prints it on startup
# open the printed URL, log in with admin / petro-demo, then follow the
# "Connect a node" view — it renders the exact scripts/30-connect-node.sh
# command wired to this demo.
```

It is an API-compatible preview, **not** the production Pterodactyl binary
(which requires PHP, MariaDB and Redis).

## Post-install hardening checklist

- [ ] Replace the generated admin password with a strong one and enable 2FA.
- [ ] Restrict SSH (keys only, non-default port).
- [ ] Enable the firewall: `ufw allow 80,443/tcp` and node ports only where needed.
- [ ] Set up MariaDB backups (`mariadb-dump panel`) and `/var/lib/pterodactyl/volumes` snapshots.
- [ ] Point `APP_URL`/`PANEL_URL` at the canonical HTTPS hostname.
