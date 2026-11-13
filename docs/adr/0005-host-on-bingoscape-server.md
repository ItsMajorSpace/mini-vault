# Host the server stack on the bingoscape server, under minivault.bingoscape.org

The server stack (ADR 0003) runs on the same Debian/Docker server as Bingoscape and is reached at `auth.`, `sync.` and `api.minivault.bingoscape.org` through that server's nginx. Mini Vault has no domain of its own yet, and this server already has nginx, TLS and a proven deploy pattern (GitHub Actions → GHCR → SSH + `deploy.sh`) that we copy. Every push to `main` that passes CI is deployed automatically; a manual run with an image tag is the rollback.

## Considered Options

- **Buy a Mini Vault domain first**: cleaner, but blocks the pipeline on a purchase for an app with no users yet.
- **One subdomain with path prefixes (`/auth`, `/sync`, `/api`)**: one DNS record, but needs nginx rewrites and it is unverified that PowerSync's client tolerates a path prefix.

## Consequences

Every app build has these URLs compiled in (`--dart-define`), so moving to another domain later means shipping a new build and keeping the old names alive until old installs are gone. Mini Vault shares RAM, ports and the nginx config with Bingoscape: its compose must not publish ports Bingoscape uses (e.g. Postgres on 5432).
