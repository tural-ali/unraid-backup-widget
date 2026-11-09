#!/bin/bash

# Uptime Kuma heartbeat. A trap, not a line at the end: these scripts exit early
# on normal paths (nothing to do, lock held, dependency absent) and a tail-placed
# push would never run, so the monitor would go DOWN on a healthy system.
_uk_hb(){ local rc=$?; /mnt/user/appdata/scripts/hc-ping.sh immich-backup "$([ $rc -eq 0 ] && echo up || echo down)" "exit=$rc"; }
trap _uk_hb EXIT
# -E so the ERR trap at the bottom also fires inside run_backup.
set -Eeuo pipefail

exec 9>/var/run/duplicacy-immich.lock
flock -n 9 || exit 0

umask 077
DUPDIR=/mnt/user/appdata/duplicacy
DUP=$DUPDIR/dup
ROOT=/mnt/user/immich/backups
CONFIG=$ROOT/config
SOURCE=/mnt/user/appdata/immich
DB=immich_postgres
LOGDIR=/mnt/user/appdata/duplicacy/logs
LOG=$LOGDIR/immich-$(date +%F).log

# shellcheck source=/dev/null
source "$DUPDIR/secret.env"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
export DUPLICACY_GDRIVE_GCD_TOKEN=$DUPDIR/tokens/gcd-token.json
export DUPLICACY_DROPBOX_DROPBOX_TOKEN
DUPLICACY_DROPBOX_DROPBOX_TOKEN=$(cat "$DUPDIR/tokens/dropbox-token.json")
# dropbox://Tower was copied from the Google Drive storage, so it shares its key.
export DUPLICACY_DROPBOX_PASSWORD="$DUPLICACY_GDRIVE_PASSWORD"

mkdir -p "$LOGDIR" "$CONFIG"
exec >>"$LOG" 2>&1

notify_failure() {
  /usr/local/emhttp/webGui/scripts/notify \
    -e "Duplicacy" \
    -s "Immich backup FAILED" \
    -d "See $LOG" \
    -i alert
}

# The nightly duplicacy run (02:30) holds duplicacy-heavy while it works. This
# used to be `flock -n 8 || exit 0` up at the top of the file, before any log
# existed - so when that run overran into this job's 04:00 slot, the entire
# backup was skipped with exit 0: no log file, no alert, nothing to notice. It
# happened on 2026-08-30, when mail.ru throttling stretched the nightly run from
# its usual 02:34 finish to 04:09, and cost a full day of Immich backups that
# the dashboard still counted as healthy.
#
# A backup that never ran must never look like one that succeeded. So: wait for
# the lock rather than give up, and if it genuinely never frees, fail loudly.
# The wait is deliberately longer than any observed nightly run. It was 90m
# until 2026-11-08, when the first Sunday prune of the paperless and appdata
# copies on Dropbox (316 old revisions) kept the nightly run going until 07:37
# and this job gave up at 05:30. Waiting is free; 6h covers a Sunday prune.
exec 8>/var/run/duplicacy-heavy.lock
if ! flock -w 21600 8; then
  echo "=== Immich backup ABORTED $(date): duplicacy-heavy held for 6h ==="
  notify_failure
  exit 1
fi

run_backup() {
  echo "=== Immich state backup started $(date) ==="
  docker inspect -f '{{.State.Running}}' "$DB" | grep -qx true

  docker exec "$DB" pg_dump \
    -U postgres \
    -d immich \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    | gzip -1 > "$ROOT/immich-db.sql.gz.tmp"
  gzip -t "$ROOT/immich-db.sql.gz.tmp"
  mv "$ROOT/immich-db.sql.gz.tmp" "$ROOT/immich-db.sql.gz"

  for name in \
    .env \
    .apikey \
    docker-compose.yml \
    docker-compose.override.yml \
    hwaccel.ml.yml \
    hwaccel.transcoding.yml \
    immich-setup.sh \
    immich-resource-guard.sh \
    system-config-before-resource-limits-20260805.json \
    system-config-before-stability-20260805.json \
    system-config-before-qsv-20260805.json
  do
    if [ -f "$SOURCE/$name" ]; then install -m 600 "$SOURCE/$name" "$CONFIG/$name"; fi
  done

  if [ -f /boot/config/plugins/dynamix/immich-resource-guard.cron ]; then
    install -m 600 /boot/config/plugins/dynamix/immich-resource-guard.cron "$CONFIG/immich-resource-guard.cron"
  fi

  if [ "${PREPARE_ONLY:-0}" = "1" ]; then
    echo "=== Immich state prepared without cloud upload $(date) ==="
    return 0
  fi

  cd "$ROOT"
  # Two cloud copies, both always attempted. Until 2026-11-07 the only one was
  # mail.ru, whose writes had been failing with 405 since its plan lapsed on
  # 2026-11-04 - unnoticed, see the note at the bottom of this file.
  local st failed=""
  for st in gdrive dropbox; do
    if ! nice -n 15 ionice -c3 "$DUP" backup -storage "$st" -stats -threads 2; then
      echo "=== $st backup FAILED $(date) ==="
      failed="$failed $st"
      continue
    fi
    if [ "$(date +%u)" = "7" ]; then
      nice -n 15 ionice -c3 "$DUP" prune -storage "$st" \
        -keep 0:365 \
        -keep 30:90 \
        -keep 7:30 \
        -keep 1:7 \
        -threads 2 \
        || { echo "=== $st prune FAILED $(date) ==="; failed="$failed $st-prune"; }
    fi
  done
  if [ -n "$failed" ]; then
    echo "=== Immich state backup FAILED:$failed $(date) ==="
    return 1
  fi

  echo "=== Immich state backup completed $(date) ==="
  touch "$LOGDIR/immich.success"
}

# Not `run_backup || notify`: bash disables `set -e` for the whole body of a
# function called on the left of `||`, so a failed pg_dump or upload carried on
# to "completed" and touched immich.success. That hid the mail.ru 405s from
# 2026-11-04 to 2026-11-07. The ERR trap keeps `set -e` live and still alerts.
trap 'rc=$?; trap - ERR; notify_failure; exit "$rc"' ERR
run_backup

