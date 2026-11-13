# Deploying the server stack

The server stack runs on the bingoscape server (ADR 0005) in `~/mini-vault`, as the compose project `mini-vault`.
Every green CI run on `main` deploys automatically through `.github/workflows/deploy.yml`, which uploads
`server/docker-compose.prod.yaml`, the Postgres init script, the PowerSync config, `server/deploy/deploy.sh` and a
`.env` rendered from GitHub secrets, then runs `deploy.sh` over SSH.

| Service   | Host port (127.0.0.1 only) | Public URL                                  |
|-----------|----------------------------|---------------------------------------------|
| GoTrue    | 9101                       | https://auth.minivault.bingoscape.org       |
| PowerSync | 9102                       | https://sync.minivault.bingoscape.org       |
| Write API | 9103                       | https://api.minivault.bingoscape.org        |
| Postgres  | not published              |                                             |

Bingoscape uses 3000 and 5432 on the same server.

`deploy.sh` backs up the database (`pg_dump`, last 10 in `~/mini-vault/backups`), pulls the images, runs `migrate`,
swaps only the `api` container and polls `http://127.0.0.1:9103/health`. If the new api is not healthy within
120 s, it puts the previous api image back. Migrations are not reverted, so a migration must work with the previous
api too. Photo files live in the `mini-vault_photos` volume and are not in these backups.

## One-time setup

1. **DNS**: A records (and AAAA if the server has IPv6) for `auth.minivault.bingoscape.org`,
   `sync.minivault.bingoscape.org` and `api.minivault.bingoscape.org`, pointing at the bingoscape server.
2. **nginx**: on the server, fetch the example config (it is not on the server yet), enable it, test and reload:
   `sudo curl -fsSL https://raw.githubusercontent.com/ItsMajorSpace/mini-vault/main/server/deploy/nginx.conf.example -o /etc/nginx/sites-available/minivault`,
   then `sudo ln -s /etc/nginx/sites-available/minivault /etc/nginx/sites-enabled/ && sudo nginx -t && sudo systemctl reload nginx`.
   A symlink without the file breaks `nginx -t` for every site on the server, Bingoscape's too.
   The sync vhost turns off proxy buffering, sets 1 h read/send timeouts and passes WebSocket upgrade headers,
   which PowerSync's streams need.
3. **TLS**: `sudo certbot --nginx -d auth.minivault.bingoscape.org -d sync.minivault.bingoscape.org -d api.minivault.bingoscape.org`.
4. **GitHub environment**: Settings → Environments → create `production`, and add these secrets to it:

   | Secret                  | Value                                                                       |
   |-------------------------|-----------------------------------------------------------------------------|
   | `SSH_HOST`              | the bingoscape server (same as bingoscape's)                                |
   | `SSH_USER`              | the deploy user (same as bingoscape's; must be able to run `docker`)        |
   | `SSH_PORT`              | SSH port                                                                    |
   | `SSH_PRIVATE_KEY`       | private key of a key in that user's `authorized_keys`                       |
   | `SSH_HOST_FINGERPRINT`  | the server's SHA256 host key fingerprint (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) |
   | `POSTGRES_PASSWORD`     | `openssl rand -hex 32`                                                      |
   | `AUTH_DB_PASSWORD`      | `openssl rand -hex 32`                                                      |
   | `POWERSYNC_DB_PASSWORD` | `openssl rand -hex 32`                                                      |
   | `JWT_SECRET`            | `openssl rand -hex 32` (at least 32 characters)                             |
   | `JWT_EXPIRY`            | optional, seconds, default 3600 (PowerSync rejects more than 24 h)          |

   The three database passwords go into connection URLs, so the workflow only accepts letters, digits and `. _ ~ -`.
   They are set in the database when its volume is first created; changing them later in GitHub alone breaks
   the stack (change the roles' passwords in Postgres too).
5. **Turn on automatic deploys**: Settings → Secrets and variables → Actions → Variables → add the repository
   variable `DEPLOY_ENABLED` = `true`. Until then, only manual runs deploy.
6. **First deploy**: Actions → Deploy to Production → Run workflow with `image_tag` = `main`, then check
   `curl https://api.minivault.bingoscape.org/health` answers 200.

The server pulls the image with the workflow's `GITHUB_TOKEN`, which works because CI publishes
`ghcr.io/itsmajorspace/mini-vault-server` from this repository.

Prod GoTrue confirms accounts without an email and has no SMTP yet, so password reset emails are not sent until
SMTP is set up (#76).

## Rollback

Actions → Deploy to Production → Run workflow, with `image_tag` set to an earlier `sha-<7 characters of the commit>`
(see the package's tags on GitHub, or `cat ~/mini-vault/.deployed-tag` for what runs now). A manual run uses the
compose file and config from `main`, with that image.

## On the server

```sh
cd ~/mini-vault
docker compose ps
docker compose logs --tail=100 api
ls backups/   # restore: gunzip -c backups/<file>.sql.gz | docker compose exec -T postgres psql -U postgres -d postgres
```
