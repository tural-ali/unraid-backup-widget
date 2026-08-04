#!/bin/bash
# Live progress for the Dropbox mirror, refreshed every minute for the dashboard.
#
# The sync script only rewrites rclone-dropbox.ini when it changes share or
# finishes, so during a multi-day seed nothing on the tile moved.
#
# Progress is counted from "Copied (new)" lines in the sync log rather than from
# rclone's own --stats output: with --log-file, this rclone build wrote no stats
# lines at all (verified - zero matches in 10k lines during an active transfer).
# Counting log lines costs a grep over a local file, so it is safe every minute,
# where asking Dropbox for remote size would burn API calls at that rate.
#
# The denominator comes from rclone-dropbox-totals.ini, written by the 6-hourly
# coverage job, so this script never walks the filesystem itself.
#
# Writes a SEPARATE file from rclone-dropbox.ini, which the sync script owns -
# two writers a minute apart would race.
#
# Output: /var/local/emhttp/rclone-dropbox-live.ini
set -u
# Configuration, shared with the settings page and the renderers. KEY="value" so
# this file is both parse_ini_file-able and source-able - one file, no second
# parser to drift. Absent config falls back to the defaults below.
CONF=/boot/config/plugins/backup-widget/config
[ -f "$CONF" ] && . "$CONF"
: "${DUP_DIR:=/mnt/user/appdata/duplicacy}"
: "${RCLONE_DIR:=/mnt/user/appdata/rclone}"

LOGDIR=$RCLONE_DIR/logs
TOTALS=/var/local/emhttp/rclone-dropbox-totals.ini
OUT=/var/local/emhttp/rclone-dropbox-live.ini
TMP="$OUT.tmp"

blank() { : > "$TMP"; mv "$TMP" "$OUT"; exit 0; }

# Only meaningful while a sync is actually running. A leftover count from a
# finished run would otherwise render as if it were still in flight.
pgrep -f "[r]clone-dropbox-sync" >/dev/null 2>&1 || blank

log=$(ls -t "$LOGDIR"/dropbox-sync-*.log 2>/dev/null | head -1)
[ -n "${log:-}" ] || blank

# Which share is in flight, per the sync script's own state file.
share=$(grep -oE 'rc_share="[^"]*"' /var/local/emhttp/rclone-dropbox.ini 2>/dev/null \
        | head -1 | cut -d'"' -f2)

# Copied lines accumulate across shares within one run, so count only those
# after the current share's banner ("=== videos -> dropbox:videos ...").
if [ -n "${share:-}" ]; then
  copied=$(awk -v s="=== $share -> " '
    index($0, s) == 1 { seen = 1; n = 0; next }
    seen && /Copied \(new\)/ { n++ }
    END { print n + 0 }' "$log")
else
  copied=$(grep -c 'Copied (new)' "$log" 2>/dev/null)
fi

total=""
if [ -n "${share:-}" ] && [ -f "$TOTALS" ]; then
  key="rt_$(echo "$share" | tr -- '-' '_')"
  total=$(grep -oE "^$key=\"[0-9]+\"" "$TOTALS" 2>/dev/null | head -1 | cut -d'"' -f2)
fi

pct=""
if [ -n "${total:-}" ] && [ "$total" -gt 0 ] 2>/dev/null; then
  pct=$(( copied * 100 / total ))
  [ "$pct" -gt 100 ] && pct=100
fi

{
  echo "rl_share=\"${share:-}\""
  echo "rl_files=\"${copied:-0}\""
  echo "rl_total_files=\"${total:-}\""
  echo "rl_pct=\"${pct:-}\""
  echo "rl_errors=\"$(grep -ci 'ERROR' "$log" 2>/dev/null)\""
  echo "rl_updated=\"$(date '+%H:%M')\""
} > "$TMP"
mv "$TMP" "$OUT"
