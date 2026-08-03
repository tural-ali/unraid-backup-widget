#!/bin/bash
# Mirror the irreplaceable shares to Dropbox as plain, browsable files.
#
# Deliberately a different KIND of copy from the Duplicacy backups on Google
# Drive and mail.ru: no chunks, no passphrase, no binary needed. In a disaster
# you open Dropbox and drag the files out. That is the whole point - a format
# problem in Duplicacy cannot take both copies with it.
#
# sync, not copy: deletions propagate, which is wanted during library cleanup.
# The safety net is Duplicacy's versioned history on Google Drive - delete
# something by mistake and it is still recoverable there for a year.
#
# Scope is chosen against a hard 3 TB ceiling that cannot be upgraded:
#   mirrored   videos, raw-photos      irreplaceable, cannot be re-sourced
#   omitted    immich                  phone backups; also in iCloud/Google Photos
#              paperless               small, and documents are better left encrypted
#              appdata                 configs; restore from Duplicacy instead
# Today that is ~1.9 TB of 3 TB, leaving room for the remaining Apple export.
set -u

R=/mnt/user/appdata/rclone
CONF=$R/config/rclone.conf
RCLONE=$R/bin/rclone
STATS=/var/local/emhttp/rclone-dropbox.ini
LOG=/mnt/user/appdata/rclone/logs/dropbox-sync-$(date +%F).log
LOCK=/var/run/rclone-dropbox.lock

SHARES="videos raw-photos"

# rc server credentials. Env, not argv: --rc-pass on the command line would be
# visible to any `ps` on the host. Loopback bind only.
export RCLONE_RC_USER=dash
export RCLONE_RC_PASS="$(cat /mnt/user/appdata/rclone/config/rc.secret 2>/dev/null)"
mkdir -p "$(dirname "$LOG")"
exec 9>"$LOCK"
flock -n 9 || { echo "already running"; exit 0; }

write_stats() {
  local tmp="$STATS.tmp"
  {
    echo "rc_state=\"$1\""
    echo "rc_share=\"${2:-}\""
    echo "rc_detail=\"${3:-}\""
    echo "rc_updated=\"$(date '+%d/%m %H:%M')\""
    [ -n "${4:-}" ] && echo "rc_used=\"$4\""
    [ -n "${5:-}" ] && echo "rc_total=\"$5\""
  } > "$tmp"
  mv "$tmp" "$STATS"
}

note() { /usr/local/emhttp/webGui/scripts/notify -e "rclone" -s "$1" -d "$2" -i "$3"; }

if ! $RCLONE --config "$CONF" listremotes 2>/dev/null | grep -q '^dropbox:'; then
  write_stats "no-remote" "" "dropbox remote not configured"
  echo "FATAL: no 'dropbox' remote in $CONF - run: $RCLONE --config $CONF config"
  exit 1
fi

write_stats "running" "" "starting"
fail=0
for s in $SHARES; do
  [ -d "/mnt/user/$s" ] || continue
  write_stats "running" "$s" "syncing"
  echo "=== $s -> dropbox:$s  $(date) ===" >> "$LOG"
  # --fast-list cuts API calls on large trees; --transfers 4 keeps within
  # Dropbox's rate limits, which throttled Duplicacy hard at higher concurrency.
  $RCLONE --config "$CONF" sync "/mnt/user/$s" "dropbox:$s" \
    --transfers 4 --checkers 8 --fast-list \
    --rc --rc-addr 127.0.0.1:5572 \
    --exclude '.DS_Store' --exclude '._*' --exclude '.duplicacy/**' \
    --exclude '**/@eaDir/**' \
    --stats 10s --stats-one-line --stats-log-level NOTICE --log-file "$LOG" --log-level INFO
  rc=$?
  if [ $rc -ne 0 ]; then
    fail=1
    note "Dropbox sync FAILED: $s" "see $LOG" alert
    echo "  rc=$rc" >> "$LOG"
  fi
done

# quota, for the dashboard - the 3 TB ceiling is the binding constraint
about=$($RCLONE --config "$CONF" about dropbox: --timeout 60s 2>/dev/null)
used=$(echo "$about" | awk '/^Used:/{print $2" "$3}')
total=$(echo "$about" | awk '/^Total:/{print $2" "$3}')

if [ "$fail" = "0" ]; then
  write_stats "ok" "" "all shares mirrored" "$used" "$total"
  echo "OK $(date)" >> "$LOG"
else
  write_stats "failed" "" "see $LOG" "$used" "$total"
fi
find "$(dirname "$LOG")" -name 'dropbox-sync-*.log' -mtime +30 -delete 2>/dev/null
