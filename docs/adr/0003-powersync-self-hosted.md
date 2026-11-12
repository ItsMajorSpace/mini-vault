# Self-hosted PowerSync + Postgres for sync

The backend runs on our own Debian/Docker server (6 GB RAM, shared with other sites): Postgres, the PowerSync Open Edition service, Supabase's standalone auth service (GoTrue) for email + password accounts, and a small Dart API that applies uploaded writes and stores photos on disk. PowerSync was the only option with an official Flutter SDK that supports offline writes and sync on iOS, Android, macOS, Windows and Linux.

## Considered Options

- **Managed Supabase (free tier)**: projects pause after inactivity, photo storage is small, and it still needs a separate offline layer.
- **Full self-hosted Supabase + Brick**: about 13 containers needing 4 GB+ RAM, the offline package is stale, and it has no conflict handling.
- **PocketBase + pocketbase_drift**: lightest to run, but both are pre-1.0 and the sync layer has a single community maintainer.
- **ElectricSQL, CouchDB, self-hosted Turso**: no working offline writes from Dart.

## Consequences

Conflicts are resolved on the server, with the latest write winning per field and deletes winning. We write and maintain the upload API and the photo storage adapter ourselves.
