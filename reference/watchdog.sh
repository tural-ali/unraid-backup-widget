#!/bin/bash
# Alerts if no successful Duplicacy run has been recorded recently.
# Exists because a crash (e.g. the dbus/keyring panic on 2026-07-28) can kill
# backup.sh before its own error handler runs, so the ABSENCE of success must
# itself be alarming. Without this, a stalled backup is invisible.
LOGDIR=/mnt/user/appdata/duplicacy/logs
H=$LOGDIR/history.log
IMMICH=$LOGDIR/immich.success
# shellcheck disable=SC2034  # read again when the iCloud hold below is lifted
ICLOUD=$LOGDIR/icloud-dropbox.success
ICLOUD_STATUS=/var/local/emhttp/icloudpd-status-cache.json
MAX_AGE_H=36
MAX_RUN_H=22

note() { /usr/local/emhttp/webGui/scripts/notify -e "Duplicacy" -s "$1" -d "$2" -i "$3"; }

check_age() {
  local label=$1 marker=$2 age
  if [ ! -e "$marker" ]; then
    note "Backup watchdog: $label has no success marker" \
         "The backup has not completed since per-repository monitoring was enabled." \
         warning
    return
  fi

  age=$(( ( $(date +%s) - $(date -r "$marker" +%s) ) / 3600 ))
  if [ "$age" -gt "$MAX_AGE_H" ]; then
    note "Backup watchdog: $label STALE" \
         "No successful run in ${age}h. Check $LOGDIR for skips, panics, or errors." \
         alert
  fi
}

check_age "core backup" "$H"
check_age "Immich" "$IMMICH"

# iCloud is intentionally ineligible until every configured iCloudPD archive is
# complete and authenticated. Do not alert while the gate is closed.
if [ -s "$ICLOUD_STATUS" ] && jq -e '
  (.instances | length >= 2) and
  all(.instances[]; .complete == true and .authIssue == false)
' "$ICLOUD_STATUS" >/dev/null 2>&1; then
  : # HOLD by user 2026-08-09: icloud backup off until re-enabled — check_age "iCloud Dropbox" "$ICLOUD"
fi

# The shared lock prevents overlap. Alert if its owner has run so long that it
# can starve the next day's jobs.
if ! flock -n /var/run/duplicacy-heavy.lock true 2>/dev/null; then
  pid=$(pgrep -o -f '/mnt/user/appdata/duplicacy/(backup|immich-backup)\.sh' || true)
  if [ -n "$pid" ]; then
    age_seconds=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    age_seconds=${age_seconds:-0}
    if [ "$age_seconds" -gt $((MAX_RUN_H * 3600)) ]; then
      note "Backup watchdog: heavy job running too long" \
           "PID $pid has held the shared backup slot for $((age_seconds / 3600))h." \
           alert
    fi
  fi
fi
