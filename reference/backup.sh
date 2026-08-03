#!/bin/bash
# Duplicacy nightly backup - Tower. See CONTEXT.md.
# Repos: raw-photos, videos, appdata, paperless
# Storages: gdrive (primary), dropbox (2nd copy of the irreplaceable set),
#           mailru (3rd copy of paperless only - small + precious)
set -u
exec 9>/var/run/duplicacy-backup.lock
flock -n 9 || exit 0

DUPDIR=/mnt/user/appdata/duplicacy
DUP=$DUPDIR/bin/duplicacy
source $DUPDIR/secret.env
# headless box: stop duplicacy's keyring from probing dbus (old godbus panics)
export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
# trust the local rclone webdav bridge cert (mail.ru storage)
export SSL_CERT_FILE=$DUPDIR/../rclone/tls/ca-bundle.crt
export DUPLICACY_GDRIVE_GCD_TOKEN=$DUPDIR/tokens/gcd-token.json
export DUPLICACY_DROPBOX_DROPBOX_TOKEN=$(cat $DUPDIR/tokens/dropbox-token.json)
export DUPLICACY_MAILRU_WEBDAV_PASSWORD="$RCLONE_WEBDAV_PASS"
export DUPLICACY_MAILRU_PASSWORD="$DUPLICACY_GDRIVE_PASSWORD"

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

# Immich: its own nightly dump (01:00) lands in immich/backups and is what
# actually restores faces, albums and curation. We do not dump again here;
# we check the dump is fresh, because a silently stopped scheduler would
# leave the cloud copy looking healthy while holding a stale database.
if docker ps --format "{{.Names}}" | grep -q "^immich_server$"; then
  newest=$(find /mnt/user/immich/backups -name "*.sql.gz" -mtime -2 2>/dev/null | wc -l)
  if [ "$newest" = "0" ]; then
    fail=1; note "Immich db dump STALE" "no dump newer than 48h in immich/backups" alert
  fi
fi

# --- primary: everything to Google Drive
for s in raw-photos videos appdata paperless immich; do
  cd /mnt/user/$s || { fail=1; note "Backup FAILED: $s" "share missing" alert; continue; }
  $DUP backup -stats -threads 4 >> "$LOG" 2>&1 || { fail=1; note "Backup FAILED: $s" "see $LOG" alert; }
done

# --- second copy: Dropbox is handled by rclone sync, NOT Duplicacy.
# A plain mirror restores by dragging files out of Dropbox - no binary, no
# password, no chunk reassembly. Deliberately a different KIND of copy from
# Google Drive, so a Duplicacy-format problem cannot affect both.
# See /mnt/user/appdata/scripts/rclone-dropbox-sync.sh
# (disabled) for s in raw-photos videos paperless immich; do
#   $DUP backup -storage dropbox ... (now rclone's job)
# done

# --- third copy: the small irreplaceable set to mail.ru.
# 1 TB sitting almost empty. raw-photos + paperless + appdata is ~319 GB and
# gives the RAW originals, documents and container configs a third copy at no
# extra cost.
# paperless first and unconditionally: ~28 MB a night, and of everything here it
# is the data with the least coverage elsewhere.
mailru_repos="paperless"

# The large repos wait while the Dropbox mirror is seeding. flock -n succeeds
# only if nothing holds the lock, so this tests for a running rclone sync
# without blocking on it. Once the seed finishes, these join automatically.
if flock -n /var/run/rclone-dropbox.lock true 2>/dev/null; then
  mailru_repos="raw-photos $mailru_repos appdata"
else
  echo "$(date '+%F %T') rclone dropbox sync in progress - deferring raw-photos and appdata to mail.ru" >> "$LOG"
fi

for s in $mailru_repos; do
  cd /mnt/user/$s || continue
  $DUP backup -storage mailru -stats -threads 3 >> "$LOG" 2>&1 \
    || { fail=1; note "mail.ru backup FAILED: $s" "see $LOG" alert; }
done

# --- weekly prune (Sundays), per-repo retention
if [ "$(date +%u)" = "7" ]; then
  # Media: cap at 365 days. Chunks of files you deleted would otherwise be kept
  # forever, and Google Drive is the capacity constraint.
  for s in raw-photos videos appdata; do
    cd /mnt/user/$s && $DUP prune -keep 0:365 -keep 30:90 -keep 7:30 -keep 1:7 >> "$LOG" 2>&1
  done
  # Documents: expire at 365 days (user decision 2026-07-28), same tiers as media.
  # Hourly snapshots still give fine-grained recovery within the last 7 days.
  # prune immich on both storages. Phone backups are the one thing here with
  # no other copy, so retention matters on the second storage too.
  cd /mnt/user/immich || true
  for st in gdrive; do
    $DUP prune -storage $st -keep 0:365 -keep 30:90 -keep 7:30 -keep 1:7 >> "$LOG" 2>&1
  done
  cd /mnt/user/paperless || true
  for st in gdrive mailru; do
    $DUP prune -storage $st -keep 0:365 -keep 30:90 -keep 7:30 -keep 1:7 >> "$LOG" 2>&1
  done
fi

/mnt/user/appdata/scripts/duplicacy-coverage.sh >/dev/null 2>&1
[ "$fail" = "0" ] && echo "OK $(date)" >> $DUPDIR/logs/history.log
find $DUPDIR/logs -name "backup-*.log" -mtime +30 -delete
exit 0
