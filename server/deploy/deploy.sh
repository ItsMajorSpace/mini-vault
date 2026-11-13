#!/usr/bin/env bash
# =============================================================================
# Mini Vault server-side deploy (ADR 0005), trimmed from bingoscape's scripts/deploy.sh.
# =============================================================================
# Run on the bingoscape server by .github/workflows/deploy.yml over SSH, after the workflow uploaded
# server/{docker-compose.prod.yaml,postgres/,powersync/,deploy/,deploy.env} to STAGE_DIR.
# Can also be run by hand from APP_DIR (STAGE_DIR=APP_DIR) for a manual deploy or rollback.
#
# Flow:
#   1. install compose file, Postgres init, PowerSync config, this script and .env (old .env kept, 5 backups)
#   2. remember the running api image ID
#   3. pull the images for IMAGE_TAG, then log out of the registry
#   4. pre-deploy pg_dump into backups/ (keeps 10; skipped if postgres is not running yet)
#   5. postgres + auth up, run migrate, powersync up (restarted if its config changed)
#   6. replace only the api container and poll its /health
#   7. record the tag in .deployed-tag
# If step 6 fails, the previous api image is restored by ID. Migrations are NOT reverted, so a migration
# must stay compatible with the previous api.
#
# Environment:
#   IMAGE_TAG           required  image tag to deploy (main, sha-<short>, v1.2.3)
#   REGISTRY_USER       required* GHCR user      (* unless SKIP_REGISTRY_LOGIN=1)
#   REGISTRY_TOKEN      required* GHCR token
#   APP_DIR             optional  default $HOME/mini-vault
#   STAGE_DIR           optional  default /tmp/mini-vault-deploy
#   HEALTH_URL          optional  default http://127.0.0.1:9103/health
#   HEALTH_TIMEOUT      optional  seconds, default 120
#   SKIP_REGISTRY_LOGIN optional  set to 1 to skip docker login/logout
# =============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/mini-vault}"
STAGE_DIR="${STAGE_DIR:-/tmp/mini-vault-deploy}"
REGISTRY=ghcr.io
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:9103/health}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
SKIP_REGISTRY_LOGIN="${SKIP_REGISTRY_LOGIN:-0}"
TAG_PATTERN='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'

SWAPPED=0
LOGGED_IN=0
PREV_TAG=""
PREV_IMAGE_ID=""
PREV_REPO=ghcr.io/itsmajorspace/mini-vault-server

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
dc() { docker compose "$@"; }

# Set or replace NAME=value in .env. Only used for IMAGE_TAG, which matches TAG_PATTERN, so needs no quoting.
set_env_var() {
    local tmp
    tmp="$(mktemp "$APP_DIR/.env.tmp.XXXXXX")"
    { grep -v "^$1=" "$APP_DIR/.env" || true; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$APP_DIR/.env"
}

registry_logout() {
    if [ "$LOGGED_IN" = "1" ]; then
        docker logout "$REGISTRY" > /dev/null 2>&1 || true
        LOGGED_IN=0
    fi
}

wait_for_health() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    log "Waiting up to ${HEALTH_TIMEOUT}s for ${HEALTH_URL}"
    while [ "$SECONDS" -lt "$deadline" ]; do
        if curl -fsS --max-time 5 -o /dev/null "$HEALTH_URL" 2> /dev/null; then
            log "api is healthy"
            return 0
        fi
        sleep 2
    done
    log "Health check timed out after ${HEALTH_TIMEOUT}s"
    return 1
}

# Restore the api container that ran before this deploy, by image ID, so it also works when its tag
# (e.g. "main") was overwritten by the pull. Runs from the EXIT trap, so errors are handled explicitly.
rollback() {
    if [ -z "$PREV_IMAGE_ID" ]; then
        return 2
    fi
    docker image inspect "$PREV_IMAGE_ID" > /dev/null 2>&1 || return 1
    local rtag="${PREV_TAG:-rollback}"
    log "Rolling back api to ${rtag} (${PREV_IMAGE_ID})"
    docker tag "$PREV_IMAGE_ID" "${PREV_REPO}:${rtag}" || return 1
    export IMAGE_TAG="$rtag"
    set_env_var IMAGE_TAG "$rtag" || return 1
    dc up -d --no-deps --wait --wait-timeout 180 --pull never api || return 1
    wait_for_health || return 1
}

on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    registry_logout
    if [ "$rc" -ne 0 ]; then
        log "DEPLOY FAILED (exit code ${rc})"
        if [ "$SWAPPED" = "1" ]; then
            log "Logs of the new api container:"
            dc logs --tail=80 api 2>&1
            rollback
            case $? in
                0) log "The previous api is running again. The failed tag was NOT deployed." ;;
                2) log "No previous api to restore (first deploy). The failed container was left in place." ;;
                *) log "ROLLBACK FAILED. Manual intervention required ('docker compose ps', 'docker compose logs api')." ;;
            esac
        else
            log "The deploy failed before the api was replaced; the running api was not touched."
        fi
    fi
    # The staged deploy.env holds secrets.
    if [ "$STAGE_DIR" != "$APP_DIR" ] && [ -f "$STAGE_DIR/docker-compose.prod.yaml" ]; then
        rm -rf "$STAGE_DIR"
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

# --- 0. validate input --------------------------------------------------------
[[ "${IMAGE_TAG:-}" =~ $TAG_PATTERN ]] || die "IMAGE_TAG is missing or invalid (allowed: letters, digits, '_', '.', '-')"
export IMAGE_TAG
if [ "$SKIP_REGISTRY_LOGIN" != "1" ]; then
    [ -n "${REGISTRY_USER:-}" ] && [ -n "${REGISTRY_TOKEN:-}" ] || die "REGISTRY_USER and REGISTRY_TOKEN are required"
fi
command -v docker > /dev/null 2>&1 || die "docker not found"
log "Deploying image tag: ${IMAGE_TAG}"

# --- 1. install files ---------------------------------------------------------
mkdir -p "$APP_DIR"
# The rendered .env has no IMAGE_TAG: keep the running one until the new api has really started.
OLD_ENV_TAG=""
if [ -f "$APP_DIR/.env" ]; then
    OLD_ENV_TAG="$(grep -E '^IMAGE_TAG=' "$APP_DIR/.env" | tail -n 1 | cut -d= -f2- || true)"
fi
# No powersync/ yet on the first deploy.
powersync_sum() { cat "$APP_DIR"/powersync/* 2> /dev/null | sha256sum || true; }
OLD_POWERSYNC="$(powersync_sum)"

if [ "$STAGE_DIR" != "$APP_DIR" ]; then
    [ -f "$STAGE_DIR/docker-compose.prod.yaml" ] || die "$STAGE_DIR/docker-compose.prod.yaml not found"
    install -m 644 "$STAGE_DIR/docker-compose.prod.yaml" "$APP_DIR/docker-compose.yaml"
    for dir in postgres powersync deploy; do
        rm -rf "${APP_DIR:?}/$dir"
        cp -R "$STAGE_DIR/$dir" "$APP_DIR/$dir"
    done
    chmod +x "$APP_DIR"/postgres/*.sh "$APP_DIR"/deploy/*.sh
    if [ -f "$STAGE_DIR/deploy.env" ]; then
        if [ -f "$APP_DIR/.env" ]; then
            cp -p "$APP_DIR/.env" "$APP_DIR/.env.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        install -m 600 "$STAGE_DIR/deploy.env" "$APP_DIR/.env"
    fi
fi
cd "$APP_DIR"
[ -f .env ] || die "$APP_DIR/.env not found"
chmod 600 .env
if [[ "$OLD_ENV_TAG" =~ $TAG_PATTERN ]]; then
    set_env_var IMAGE_TAG "$OLD_ENV_TAG"
fi
# Keep the newest 5 .env backups (they hold secrets).
# shellcheck disable=SC2012 # names are generated above, no odd characters
ls -1t .env.backup.* 2> /dev/null | tail -n +6 | xargs -r rm -f -- || true

# --- 2. remember what is running now ------------------------------------------
if [ -s .deployed-tag ]; then
    PREV_TAG="$(head -n 1 .deployed-tag)"
    [[ "$PREV_TAG" =~ $TAG_PATTERN ]] || PREV_TAG=""
fi
PREV_CONTAINER="$(dc ps -q --status running api 2> /dev/null | head -n 1 || true)"
if [ -n "$PREV_CONTAINER" ]; then
    PREV_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$PREV_CONTAINER" 2> /dev/null || true)"
    log "Currently running: ${PREV_TAG:-unknown tag} (${PREV_IMAGE_ID})"
else
    log "No api container is running yet (first deploy): rollback is not possible"
fi

# --- 3. pull images -----------------------------------------------------------
log "Pulling images"
if [ "$SKIP_REGISTRY_LOGIN" != "1" ]; then
    printf '%s' "$REGISTRY_TOKEN" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin > /dev/null
    LOGGED_IN=1
fi
dc pull --quiet
registry_logout

# --- 4. pre-deploy backup -----------------------------------------------------
if [ -n "$(dc ps -q --status running postgres 2> /dev/null)" ]; then
    mkdir -p backups
    chmod 700 backups
    backup="backups/pre-deploy-$(date +%Y%m%d_%H%M%S)-${IMAGE_TAG}.sql.gz"
    log "Backing up the database to $backup"
    dc exec -T postgres pg_dump -U postgres -d postgres --clean --if-exists | gzip > "$backup" \
        || { rm -f "$backup"; die "Pre-deploy backup failed, aborting"; }
    gzip -t "$backup" || die "Pre-deploy backup is corrupt, aborting"
    # shellcheck disable=SC2012 # names are generated above, no odd characters
    ls -1t backups/pre-deploy-*.sql.gz | tail -n +11 | xargs -r rm -f --
else
    log "postgres is not running (first deploy?), skipping backup"
fi

# --- 5. database, auth, migrations, sync --------------------------------------
log "Starting postgres and auth"
dc up -d --wait --wait-timeout 180 postgres auth
log "Running migrations"
dc run --rm -T migrate
if [ "$(powersync_sum)" != "$OLD_POWERSYNC" ] && [ -n "$(dc ps -q powersync 2> /dev/null)" ]; then
    log "PowerSync config changed, restarting powersync"
    dc restart powersync
fi
dc up -d --no-deps --wait --wait-timeout 180 powersync

# --- 6. swap the api ----------------------------------------------------------
log "Starting api ${IMAGE_TAG}"
SWAPPED=1
# Recorded in .env so manual 'docker compose' calls on the server use it too.
set_env_var IMAGE_TAG "$IMAGE_TAG"
dc up -d --no-deps --remove-orphans --wait --wait-timeout 180 api
wait_for_health

# --- 7. done ------------------------------------------------------------------
printf '%s\n' "$IMAGE_TAG" > .deployed-tag.tmp
mv .deployed-tag.tmp .deployed-tag
SWAPPED=0
docker image prune -f > /dev/null 2>&1 || true
dc ps
log "Deploy of ${IMAGE_TAG} succeeded"
