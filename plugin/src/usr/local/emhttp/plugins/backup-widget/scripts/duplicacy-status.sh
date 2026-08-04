#!/bin/bash
# Writes a compact status file for the Duplicacy dashboard tile.
# Runs every minute from cron. Cheap: tail + regex on the current log.
# Output is an ini file so the .page can parse_ini_file() it defensively.
set -u
# Configuration, shared with the settings page and the renderers. KEY="value" so
# this file is both parse_ini_file-able and source-able - one file, no second
# parser to drift. Absent config falls back to the defaults below.
CONF=/boot/config/plugins/backup-widget/config
[ -f "$CONF" ] && . "$CONF"
: "${DUP_DIR:=/mnt/user/appdata/duplicacy}"
: "${RCLONE_DIR:=/mnt/user/appdata/rclone}"

D=$DUP_DIR
OUT=/var/local/emhttp/duplicacy.ini
TMP="$OUT.tmp"
LOG="$D/logs/backup-$(date +%F).log"
PLOG="$D/logs/paperless-$(date +%F).log"

status="idle"; repo=""; pct=""; speed=""; eta=""

# /var/local/emhttp is a RAM filesystem, so the coverage file is lost on every
# reboot and its own cron only fires at 00:05/06:05/12:05/18:05 - leaving the
# dashboard matrix blank for up to 6h. Since this script runs every minute,
# rebuild the coverage file here if it is missing. Backgrounded because a
# coverage pass hits three clouds and takes 40-120s.
COV=/var/local/emhttp/duplicacy-coverage.ini
if [ ! -f "$COV" ] && ! pgrep -f "[d]uplicacy-coverage.sh" >/dev/null; then
  /boot/config/plugins/backup-widget/scripts/duplicacy-coverage.sh >/dev/null 2>&1 &
fi

# Is a backup running? Identify the repo from the process working directory.
for p in $(pgrep -f "duplicacy backup" 2>/dev/null); do
  cwd=$(readlink "/proc/$p/cwd" 2>/dev/null)
  case "$cwd" in
    /mnt/user/*) status="running"; repo="${cwd##*/}"; break ;;
  esac
done

# Most recent progress line from whichever log was touched last
newest="$LOG"
[ -f "$PLOG" ] && [ "$PLOG" -nt "$LOG" ] && newest="$PLOG"
if [ -f "$newest" ]; then
  # backup.sh appends every repo to one log in sequence, and progress lines do
  # not name their repo. So a progress line is only valid for the repo we
  # detected from the process CWD if no NEW repo has started since that line.
  # "Storage set to" marks a repo starting. Without this check the tile showed
  # "videos 99.9%" while 99.9% was really raw-photos finishing (2026-07-28).
  prog_ln=$(grep -nE "(Uploaded|Skipped) chunk" "$newest" 2>/dev/null | tail -1 | cut -d: -f1)
  start_ln=$(grep -n "Storage set to" "$newest" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -n "$prog_ln" ] && { [ -z "$start_ln" ] || [ "$start_ln" -lt "$prog_ln" ]; }; then
    line=$(sed -n "${prog_ln}p" "$newest")
    speed=$(echo "$line" | grep -oE '[0-9.]+[KMG]B/s' | tail -1)
    pct=$(echo "$line" | grep -oE '[0-9.]+%' | tail -1)
    eta=$(echo "$line" | sed -nE 's/.*B\/s ([0-9a-zA-Z: ]+) [0-9.]+%.*/\1/p')
  elif [ "$status" = "running" ]; then
    # Repo has started but not yet reported progress (scanning, listing chunks).
    eta="scanning"
  fi
fi

# Last successful full run
last_ok="never"
if [ -s "$D/logs/history.log" ]; then
  last_ok=$(date -r "$D/logs/history.log" "+%d %b %H:%M" 2>/dev/null || echo "unknown")
fi

# Repos finished today, de-duplicated, newest revision only
done_today=$(grep -hoE "Backup for /mnt/user/[a-z-]+ at revision [0-9]+ completed" \
  "$D/logs/backup-$(date +%F).log" "$PLOG" 2>/dev/null \
  | sed -E 's|Backup for /mnt/user/||; s| at revision | r|; s| completed||' \
  | awk '{a[$1]=$2} END {for (k in a) printf "%s %s  ", k, a[k]}')

{
  echo "status=\"$status\""
  echo "repo=\"$repo\""
  echo "pct=\"$pct\""
  echo "speed=\"$speed\""
  echo "eta=\"$eta\""
  echo "last_ok=\"$last_ok\""
  echo "done_today=\"$done_today\""
  echo "updated=\"$(date '+%H:%M')\""
} > "$TMP" && mv "$TMP" "$OUT"
