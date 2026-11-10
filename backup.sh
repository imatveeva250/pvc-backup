#!/bin/sh
# Back up one PVC to a restic repository.
#
# 1. Copy everything from SOURCE_DIR to STAGE_DIR, except the SQLite databases
#    listed in SQLITE_DBS (and their -wal/-shm/-journal files) and EXCLUDES.
# 2. Copy each database with sqlite3 ".backup": a consistent copy that includes
#    changes still in the WAL, then check it with PRAGMA integrity_check.
# 3. restic backup STAGE_DIR, forget and prune old snapshots, and run a full
#    check (reading all data) on CHECK_WEEKDAY.
# 4. Ping healthchecks.io: /start at the beginning, success at the end,
#    /<exit code> if any step fails (healthchecks.io counts non-zero as a failure).
#
# Required: RESTIC_REPOSITORY, RESTIC_PASSWORD, RESTIC_TAG, and the
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY of the S3 bucket.
# Optional: HC_PING_URL, SQLITE_DBS, EXCLUDES (both space-separated paths
# relative to SOURCE_DIR), KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY, CHECK_WEEKDAY.

set -eu
# busybox ash supports pipefail; without it a failing first tar would go unnoticed
set -o pipefail

SOURCE_DIR="${SOURCE_DIR:-/data}"
STAGE_DIR="${STAGE_DIR:-/stage}"
SQLITE_DBS="${SQLITE_DBS:-}"
EXCLUDES="${EXCLUDES:-}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
CHECK_WEEKDAY="${CHECK_WEEKDAY:-7}"   # 1 = Monday ... 7 = Sunday
HC_PING_URL="${HC_PING_URL:-}"

: "${RESTIC_REPOSITORY:?not set}"
: "${RESTIC_PASSWORD:?not set}"
: "${RESTIC_TAG:?not set}"

# The pod name changes on every run. restic groups snapshots by host for
# "forget", so a random host would mean nothing is ever forgotten.
HOST="${RESTIC_HOST:-veneticapi}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

ping_hc() {
    [ -n "$HC_PING_URL" ] || return 0
    curl -fsS -m 10 --retry 3 -o /dev/null "${HC_PING_URL}$1" || log "healthchecks ping $1 failed"
}

on_exit() {
    code=$?
    if [ "$code" -ne 0 ]; then
        log "backup FAILED with exit code $code"
        ping_hc "/$code"   # healthchecks.io treats a non-zero exit status as a failure
    fi
}
trap on_exit EXIT

ping_hc "/start"

# Repository: create it on the first run only. restic exits with 10 when the
# repository does not exist; any other error (network, wrong password) stops here.
set +e
restic cat config >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 10 ]; then
    log "repository does not exist, initialising"
    restic init
elif [ "$rc" -ne 0 ]; then
    log "cannot open repository (restic exit code $rc)"
    restic cat config >/dev/null   # run again to show the error, then exit
fi

# Stage: everything except the live databases and the excludes.
log "staging $SOURCE_DIR"
excl_file="$(mktemp)"
for db in $SQLITE_DBS; do
    for suffix in "" -wal -shm -journal; do
        echo "./${db}${suffix}" >> "$excl_file"
    done
done
for e in $EXCLUDES; do
    echo "./${e}" >> "$excl_file"
done

# Archive the entries inside SOURCE_DIR, not "." itself. STAGE_DIR is a volume
# mount owned by root; with a "." entry tar would try to copy the source
# directory's mode and times onto it, which a non-root user may not do.
( cd "$SOURCE_DIR" && find . -mindepth 1 -maxdepth 1 -print0 ) \
    | tar -C "$SOURCE_DIR" -X "$excl_file" --null -T - -cf - \
    | tar -C "$STAGE_DIR" -xf -

# Databases: consistent online copy, then verify the copy.
for db in $SQLITE_DBS; do
    log "copying database $db"
    mkdir -p "$(dirname "$STAGE_DIR/$db")"
    sqlite3 "$SOURCE_DIR/$db" ".backup '$STAGE_DIR/$db'"
    result="$(sqlite3 "$STAGE_DIR/$db" "PRAGMA integrity_check;")"
    if [ "$result" != "ok" ]; then
        log "integrity check failed for $db: $result"
        exit 1
    fi
done

log "restic backup"
restic backup --host "$HOST" --tag "$RESTIC_TAG" "$STAGE_DIR"

log "restic forget and prune"
restic forget --host "$HOST" --tag "$RESTIC_TAG" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
    --prune

if [ "$(date -u +%u)" = "$CHECK_WEEKDAY" ]; then
    log "restic check, reading all data"
    restic check --read-data
fi

log "backup finished"
ping_hc ""
