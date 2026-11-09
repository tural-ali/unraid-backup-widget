#!/bin/bash

# Uptime Kuma heartbeat. A trap, not a line at the end: these scripts exit early
# on normal paths (nothing to do, lock held, dependency absent) and a tail-placed
# push would never run, so the monitor would go DOWN on a healthy system.
# Hourly Paperless snapshot - Google Drive + Dropbox.
# Lives on Tower at /mnt/user/appdata/duplicacy/paperless-hourly.sh
#
# Rationale: mail is ingested every 5 minutes, so a daily snapshot could lose a
# day of filing. The repo is ~2.6GB and deduplicated, so hourly incrementals cost
# very little. Gives Time-Machine-like granularity: every hour for the last 7
# days, then daily, weekly, and monthly kept indefinitely (pruned by backup.sh).
# The second cloud copy was mail.ru until 2026-11-07, when its plan lapsed to
# 8 GiB and every write failed with 405. It now goes to dropbox://Tower, the
# storage family-archive already uses.
set -u
exec 9>/var/run/duplicacy-paperless.lock
flock -n 9 || exit 0

DUPDIR=/mnt/user/appdata/duplicacy
DUP=$DUPDIR/bin/duplicacy
source $DUPDIR/secret.env
export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
export DUPLICACY_GDRIVE_GCD_TOKEN=$DUPDIR/tokens/gcd-token.json
DUPLICACY_DROPBOX_DROPBOX_TOKEN=$(cat $DUPDIR/tokens/dropbox-token.json)
export DUPLICACY_DROPBOX_DROPBOX_TOKEN
export DUPLICACY_DROPBOX_PASSWORD="$DUPLICACY_GDRIVE_PASSWORD"

# How long we are willing to stand aside for the nightly run. The nightly covers
# raw-photos, videos, appdata, paperless and immich across three storages and can
# exceed 24h on a big delta - on 2026-08-02 its Dropbox leg alone had 13h left
# after 15h of running. Skipping "while the nightly holds its lock" therefore
# starved this job for over 40 hours and left the dbdump a day stale. Past this
# grace we accept some upload contention: paperless is small and precious, and a
# missing hourly snapshot is the worse outcome.
NIGHTLY_GRACE=7200   # 2 hours

# Dead-man's switch. A Tailnet-only stack cannot be polled from outside, so the
# backup reports outward instead; no ping is itself the alert.
HC="${DUPLICACY_HC_PING_URL:-https://hc-ping.com/<check-uuid>}"

LOG=$DUPDIR/logs/paperless-$(date +%F).log
mkdir -p $DUPDIR/logs
note() { /usr/local/emhttp/webGui/scripts/notify -e "Duplicacy" -s "$1" -d "$2" -i "$3"; }
hc() {  # hc <path> [body]
  [ -n "$HC" ] || return 0
  if [ -n "${2:-}" ]; then
    curl -fsS -m 15 --retry 2 --data-raw "$2" "$HC$1" >/dev/null 2>&1 || true
  else
    curl -fsS -m 15 --retry 2 "$HC$1" >/dev/null 2>&1 || true
  fi
}

# Stand aside for a *normal-length* nightly, but never indefinitely.
if ! flock -n 8 2>/dev/null 8>/var/run/duplicacy-backup.lock; then
  npid=$(pgrep -f "$DUPDIR/backup.sh" | head -1)
  nage=$(ps -o etimes= -p "${npid:-0}" 2>/dev/null | tr -d ' ')
  nage=${nage:-0}
  if [ "$nage" -lt "$NIGHTLY_GRACE" ]; then
    exit 0
  fi
  echo "$(date '+%F %T') nightly running for ${nage}s (> ${NIGHTLY_GRACE}s) - proceeding anyway" >> "$LOG"
fi

docker ps --format "{{.Names}}" | grep -q "^paperless-db$" || exit 0

failed=""
if docker exec paperless-db pg_dump -U paperless -Fc paperless > /mnt/user/paperless/dbdump/paperless.pgcustom.tmp 2>>"$LOG"; then
  mv /mnt/user/paperless/dbdump/paperless.pgcustom.tmp /mnt/user/paperless/dbdump/paperless.pgcustom
else
  note "Paperless hourly: pg_dump FAILED" "see $LOG" alert
  hc /fail "pg_dump failed - see $LOG"
  exit 1
fi

cd /mnt/user/paperless || { hc /fail "/mnt/user/paperless missing"; exit 1; }
nice -n 15 ionice -c3 "$DUP" backup -stats -threads 1 >> "$LOG" 2>&1 \
  || { failed="$failed gdrive"; note "Paperless hourly: Google Drive FAILED" "see $LOG" alert; }
nice -n 15 ionice -c3 "$DUP" backup -storage dropbox -stats -threads 1 >> "$LOG" 2>&1 \
  || { failed="$failed dropbox"; note "Paperless hourly: Dropbox FAILED" "see $LOG" alert; }

if [ -n "$failed" ]; then
  hc /fail "storage failed:$failed - see $LOG"
else
  hc "" ""
fi

find $DUPDIR/logs -name "paperless-*.log" -mtime +14 -delete
[ -z "$failed" ]
