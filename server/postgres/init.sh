#!/bin/sh
# Runs once, when the Postgres volume is first created. The synced tables are created later by
# `server migrate`, because their starter-Workflow trigger needs GoTrue's auth.users table.
set -eu

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v auth_pw="$AUTH_DB_PASSWORD" -v powersync_pw="$POWERSYNC_DB_PASSWORD" <<'SQL'
-- GoTrue keeps its tables in the auth schema, as in its own dev setup (supabase/auth hack/init_postgres.sql).
CREATE ROLE supabase_auth_admin NOINHERIT CREATEROLE LOGIN PASSWORD :'auth_pw';
CREATE SCHEMA auth AUTHORIZATION supabase_auth_admin;
GRANT CREATE ON DATABASE postgres TO supabase_auth_admin;
ALTER ROLE supabase_auth_admin SET search_path = auth;

-- PowerSync reads the synced tables through logical replication and keeps its buckets in its own database.
CREATE ROLE powersync_role LOGIN REPLICATION PASSWORD :'powersync_pw';
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO powersync_role;
CREATE DATABASE powersync_storage OWNER powersync_role;
SQL
