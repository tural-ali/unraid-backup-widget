#!/bin/bash

# Uptime Kuma heartbeat. A trap, not a line at the end: these scripts exit early
# on normal paths (nothing to do, lock held, dependency absent) and a tail-placed
# push would never run, so the monitor would go DOWN on a healthy system.
# shellcheck disable=SC2329  # invoked by the EXIT trap
_uk_hb(){ local rc=$?; /mnt/user/appdata/scripts/hc-ping.sh duplicacy-backup "$([ "$rc" -eq 0 ] && echo up || echo down)" "exit=$rc"; }
trap _uk_hb EXIT
# Duplicacy nightly backup - Tower. See CONTEXT.md.
# Repos: family-archive (video + RAW), appdata, paperless. raw-photos retired 2026-08-07 - its snapshots are kept for restore but it is no longer backed up.
# Storages: gdrive (primary), dropbox (dropbox://Tower: family-archive, plus the
# second copy of the irreplaceable set), local (paperless on the array).
# mail.ru held that second copy until 2026-11-07, when its plan lapsed to 8 GiB.
set -u
exec 9>/var/run/duplicacy-backup.lock
flock -n 9 || exit 0
# duplicacy-heavy is shared with immich-backup.sh and duplicacy-check.sh. Wait
# for it rather than `|| exit 0`: a skipped night must page, not ping "up".
exec 8>/var/run/duplicacy-heavy.lock
if ! flock -w 10800 8; then
  /usr/local/emhttp/webGui/scripts/notify -e "Duplicacy" -s "Nightly backup ABORTED" \
    -d "duplicacy-heavy held for 3h" -i alert
  exit 1
fi

DUPDIR=/mnt/user/appdata/duplicacy
DUP=$DUPDIR/bin/duplicacy
# shellcheck source=/dev/null
source $DUPDIR/secret.env
# headless box: stop duplicacy's keyring from probing dbus (old godbus panics)
export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
export DUPLICACY_GDRIVE_GCD_TOKEN=$DUPDIR/tokens/gcd-token.json
DUPLICACY_DROPBOX_DROPBOX_TOKEN=$(cat $DUPDIR/tokens/dropbox-token.json)
export DUPLICACY_DROPBOX_DROPBOX_TOKEN
export DUPLICACY_DROPBOX_PASSWORD="$DUPLICACY_GDRIVE_PASSWORD"

LOG=$DUPDIR/logs/backup-$(date +%F).log
mkdir -p $DUPDIR/logs
note() { /usr/local/emhttp/webGui/scripts/notify -e "Duplicacy" -s "$1" -d "$2" -i "$3"; }
fail=0

# Paperless: dump postgres first. The live db/ dir is excluded from the backup
# because copying running postgres data files yields unrestorable snapshots.
if docker ps --format "{{.Names}}" | grep -q "^paperless-db$"; then
  if docker exec paperless-db pg_dump -U paperless -Fc paperless > /mnt/user/paperless/dbdump/paperless.pgcustom.tmp 2>>"$LOG"; then
    mv /mnt/user/paperless/dbdump/paperless.pgcustom.tmp /mnt/user/paperless/dbdump/paperless.pgcustom
  else
    fail=1; note "Paperless pg_dump FAILED" "see $LOG" alert
  fi
fi

# family-archive: backed up to DROPBOX since 2026-09-05.
#
# The storage moved off Google Drive because Drive is being repurposed to hold a
# full clone of the share (3.32 TiB), which cannot fit alongside 2.5 TiB of
# chunks. The storage was copied Drive -> Dropbox and then verified in place with
# `duplicacy check -all`: 382 revisions across all four snapshot ids, zero
# missing chunks, config byte-identical to the Drive original.
#
# Keeps its own lock (fd 8) so a long media backup cannot overlap the next night.
(
  flock -n 8 || { echo "family-archive: backup already running, skipped $(date)" >> "$LOG"; exit 0; }
  cd /mnt/user/family-archive || { note "Backup FAILED: family-archive" "share missing" alert; exit 1; }
  nice -n 15 ionice -c3 "$DUP" backup -storage dropbox -stats -threads 4 >> "$LOG" 2>&1 \
    || { note "Backup FAILED: family-archive" "see $LOG" alert; exit 1; }
) 8>/var/run/duplicacy-family-archive.lock || fail=1

# appdata: consistent copies of the live databases, which prefs/appdata/filters
# excludes because a copy of a file under active writes is torn. Ghost's MySQL
# dump lands in ghost/backups, the SQLite snapshots in backups/live-db. Both run
# right before the appdata leg so each night's revision holds that night's copy
# (the Ghost dump used to run from its own 03:15 cron, after this backup).
if docker ps --format "{{.Names}}" | grep -q "^ghost-db$"; then
  /mnt/user/appdata/ghost/backup-db.sh >> /mnt/user/appdata/ghost/backup.log 2>&1 \
    || { fail=1; note "Ghost DB dump FAILED" "see /mnt/user/appdata/ghost/backup.log" alert; }
else
  fail=1; note "Ghost DB dump FAILED" "ghost-db is not running" alert
fi
"$DUPDIR/db-snapshots.sh" >> "$LOG" 2>&1 \
  || { fail=1; note "Database snapshots FAILED" "see $LOG" alert; }

# --- primary: everything to Google Drive
for s in appdata paperless; do  # family-archive handled above, under its own lock
  cd /mnt/user/$s || { fail=1; note "Backup FAILED: $s" "share missing" alert; continue; }
  nice -n 15 ionice -c3 "$DUP" backup -stats -threads 2 >> "$LOG" 2>&1 || { fail=1; note "Backup FAILED: $s" "see $LOG" alert; }
done

# --- third copy: paperless onto the array.
# paperless is the only share that *lives* on the cache pool instead of passing
# through it (shareUseCache="prefer"), and that pool is a single NVMe with no
# redundancy. So unlike every other repo here, losing that device loses the live
# copy outright and the only survivors are in the cloud. This leg puts a
# parity-protected copy on disk1, which restores in minutes rather than pulling
# gigabytes back down a domestic uplink.
#
# It backs up the same tree the cloud legs do, so it inherits the consistent
# pg_dump taken at the top of this script rather than a torn copy of a running
# postgres data directory - which is why this is a duplicacy leg and not an rsync.
#
# Daily, deliberately, not hourly: the cloud legs already give hourly
# granularity, and an hourly local leg would spin an array disk up around the
# clock while adding no recovery ability that is not already there.
export DUPLICACY_LOCAL_PASSWORD="$DUPLICACY_GDRIVE_PASSWORD"
if cd /mnt/user/paperless; then
  nice -n 15 ionice -c3 "$DUP" backup -storage local -stats -threads 2 >> "$LOG" 2>&1 \
    || { fail=1; note "Local backup FAILED: paperless" "see $LOG" alert; }
else
  fail=1; note "Local backup FAILED: paperless" "share missing" alert
fi

# --- second cloud copy: the irreplaceable set to Dropbox.
# Same storage as family-archive (dropbox://Tower), so chunks dedupe with the
# paperless and appdata revisions copied there from Google Drive in September.
# This was mail.ru until 2026-11-07, when the plan lapsed to 8 GiB and every
# write failed with 405. paperless first: smallest, and the least replaceable.
for s in paperless appdata; do
  cd /mnt/user/$s || { fail=1; note "Dropbox backup FAILED: $s" "share missing" alert; continue; }
  nice -n 15 ionice -c3 "$DUP" backup -storage dropbox -stats -threads 4 >> "$LOG" 2>&1 \
    || { fail=1; note "Dropbox backup FAILED: $s" "see $LOG" alert; }
done

# --- weekly prune (Sundays), per-repo retention
if [ "$(date +%u)" = "7" ]; then
  echo "=== weekly prune started $(date) ===" >> "$LOG"
  # Media: cap at 365 days. Chunks of files you deleted would otherwise be kept
  # forever, and Google Drive is the capacity constraint.
  # family-archive lives on Dropbox only; appdata is on Google Drive and Dropbox.
  # Prune takes no -all on purpose: dropbox://Tower also holds the retired
  # tower-raw-photos snapshots, which are kept for restore and must not age out.
  cd /mnt/user/family-archive && nice -n 15 ionice -c3 "$DUP" prune -storage dropbox -keep 0:365 -keep 30:90 -keep 7:30 -keep 1:7 >> "$LOG" 2>&1
  cd /mnt/user/appdata || true
  for st in gdrive dropbox; do
    nice -n 15 ionice -c3 "$DUP" prune -storage $st -keep 0:365 -keep 30:90 -keep 7:30 -keep 1:7 >> "$LOG" 2>&1
  done
  # Documents: expire at 365 days (user decision 2026-07-28), same tiers as media.
  # Hourly snapshots still give fine-grained recovery within the last 7 days.
  cd /mnt/user/paperless || true
  for st in gdrive dropbox local; do
    nice -n 15 ionice -c3 "$DUP" prune -storage $st -keep 0:365 -keep 30:90 -keep 7:30 -keep 1:7 >> "$LOG" 2>&1
  done
  echo "=== weekly prune finished $(date) ===" >> "$LOG"
fi

nice -n 15 ionice -c3 bash /boot/config/plugins/backup-widget/scripts/duplicacy-coverage.sh >/dev/null 2>&1  # bash: /boot is noexec
[ "$fail" = "0" ] && echo "OK $(date)" >> $DUPDIR/logs/history.log
find $DUPDIR/logs -name "backup-*.log" -mtime +30 -delete
# Exit with the failure flag so the Uptime Kuma heartbeat (the EXIT trap at the
# top) reports DOWN on a night where any leg failed, not just when the script dies.
exit "$fail"
