# Troubleshooting

All installer scripts use `set -Eeuo pipefail` and stop on the first failing
command with its line number. They are safe to re-run after fixing the issue.

## Logs

| Component | Command |
| --- | --- |
| Panel (PHP-FPM) | `tail -f /var/log/nginx/pterodactyl_error.log` |
| Nginx | `journalctl -u nginx -f` |
| Queue worker | `journalctl -u pteroq -f` |
| MariaDB | `journalctl -u mariadb -f` |
| Redis | `journalctl -u redis-server -f` |
| Wings | `journalctl -u wings -f` |
| Wings self-test | `wings diagnostics` |

## Panel

### `composer install` fails downloading packages
Check outbound access to `getcomposer.org` and Packagist. On locked-down
networks configure a mirror: `composer config -g repos.packagist composer <mirror>`.

### `artisan migrate` fails with database errors
- Confirm credentials: `mysql -h 127.0.0.1 -u pterodactyl -p panel`.
- The generated password lives in `/root/.petro-panel.env`; `.env` in the panel
  directory must contain the same value.
- Re-run `php artisan p:environment:database` and `php artisan migrate --seed`.

### 502 Bad Gateway
PHP-FPM is down or the socket path differs. Check
`ls /run/php/` and align the `fastcgi_pass` line in
`/etc/nginx/sites-available/pterodactyl` with the installed socket
(e.g. `/run/php/php8.3-fpm.sock`), then `systemctl restart php8.3-fpm nginx`.

### Web UI shows cache/session errors
Redis must be running: `systemctl restart redis-server pteroq`, then
`cd /var/www/pterodactyl && php artisan config:cache`.

### Permission errors in `storage/`
```bash
chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache
```

## Certbot

- The FQDN must resolve publicly to this server and port 80 must be open.
- IP addresses cannot get Let's Encrypt certificates — set `PANEL_SSL=false`
  or front the panel with a reverse proxy.
- Re-run manually: `certbot --nginx -d panel.example.com --redirect`.

## Wings / nodes

### Node stays red (no heartbeat)
1. `journalctl -u wings -n 100` — token or URL errors appear here.
2. Verify `/etc/pterodactyl/config.yml` exists and `remote` matches `PANEL_URL`.
3. The node firewall must allow 8080/tcp and 2022/tcp inbound.
4. `wings diagnostics` checks Docker, the socket and API connectivity.

### `docker: Cannot connect to the Docker daemon`
`systemctl enable --now docker`. On virtualized hosts confirm nested
virtualization / privileged mode is allowed; Wings requires a working Docker
daemon and cannot run game servers without it.

### `wings configure` returns 401/403
The `ptla_` key is missing, expired, or lacks write permission on nodes.
Recreate it under **Admin → Application API** and re-run
`sudo ./install.sh node`.

### Allocation port already in use
Remove or replace the allocation in **Admin → Nodes → Allocations**, or free
the port on the host (`ss -ltnp | grep <port>`).

### Changing node resources
Edit the node in **Admin → Nodes** (or PATCH it via the Application API); most
changes only need `systemctl restart wings`. Changing FQDN/scheme requires a
fresh `wings configure --override`.

## Resetting generated secrets

Secrets are kept in `/root/.petro-panel.env` (mode 600). Deleting a line causes
a new value to be generated on the next run — but for `DB_PASSWORD` you must
then update the MariaDB user as well:

```sql
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY 'new-password';
FLUSH PRIVILEGES;
```
