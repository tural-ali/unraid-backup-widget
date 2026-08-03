#!/bin/bash
# Real byte-level progress for the Dropbox mirror: transferred, total, rate, ETA.
#
# Why this exists rather than parsing rclone's own stats: with --log-file, this
# build wrote no --stats lines at all - verified, zero matches across 10k lines
# during an active transfer. So progress is measured from the outside, by asking
# Dropbox how many bytes of the current share have arrived.
#
# One listing call per run, so this runs every 5 minutes, not every minute.
# Rate and ETA come from the delta against the previous sample, which is why the
# previous sample is persisted. First run after a restart reports bytes but no
# rate - there is nothing to compare against yet, and inventing a rate would be
# worse than admitting it is not known.
#
# Output: /var/local/emhttp/rclone-progress.ini
# State:  /mnt/user/appdata/rclone/.progress-sample
set -u
R=/mnt/user/appdata/rclone
C=$R/config/rclone.conf
OUT=/var/local/emhttp/rclone-progress.ini
TMP="$OUT.tmp"
SAMPLE=$R/.progress-sample
TOTALS=/var/local/emhttp/backup-inventory.ini

EX=(--exclude '.DS_Store' --exclude '._*' --exclude '.duplicacy/**' --exclude '**/@eaDir/**')

blank() { : > "$TMP"; mv "$TMP" "$OUT"; exit 0; }

pgrep -f "[r]clone-dropbox-sync" >/dev/null 2>&1 || { rm -f "$SAMPLE"; blank; }

share=$(grep -oE 'rc_share="[^"]*"' /var/local/emhttp/rclone-dropbox.ini 2>/dev/null \
        | head -1 | cut -d'"' -f2)
[ -n "${share:-}" ] || blank

now=$(date +%s)
done_b=$(timeout 300 "$R/bin/rclone" --config "$C" size "dropbox:$share" --fast-list --json 2>/dev/null \
         | grep -oE '"bytes":[0-9]+' | head -1 | cut -d: -f2)
[ -n "${done_b:-}" ] || blank

# Denominator from the local inventory: the same share measured locally.
key="inv_$(echo "$share" | tr -- '-' '_')_bytes"
total_b=$(grep -oE "^$key=\"[0-9]+\"" "$TOTALS" 2>/dev/null | head -1 | cut -d'"' -f2)

rate=0
if [ -f "$SAMPLE" ]; then
  read -r p_share p_time p_bytes < "$SAMPLE" 2>/dev/null || true
  if [ "${p_share:-}" = "$share" ] && [ -n "${p_time:-}" ] && [ "$now" -gt "${p_time:-0}" ]; then
    d_bytes=$(( done_b - ${p_bytes:-0} ))
    d_time=$(( now - p_time ))
    [ "$d_bytes" -gt 0 ] && rate=$(( d_bytes / d_time ))
  fi
fi
printf '%s %s %s\n' "$share" "$now" "$done_b" > "$SAMPLE"

pct=""; eta=""
if [ -n "${total_b:-}" ] && [ "$total_b" -gt 0 ] 2>/dev/null; then
  pct=$(( done_b * 100 / total_b ))
  [ "$pct" -gt 100 ] && pct=100
  if [ "$rate" -gt 0 ]; then
    remain=$(( total_b - done_b ))
    [ "$remain" -lt 0 ] && remain=0
    secs=$(( remain / rate ))
    if   [ "$secs" -ge 86400 ]; then eta="$(( secs / 86400 ))d $(( (secs % 86400) / 3600 ))h"
    elif [ "$secs" -ge 3600 ];  then eta="$(( secs / 3600 ))h $(( (secs % 3600) / 60 ))m"
    else                             eta="$(( secs / 60 ))m"
    fi
  fi
fi

{
  echo "pg_share=\"$share\""
  echo "pg_done=\"$done_b\""
  echo "pg_total=\"${total_b:-}\""
  echo "pg_pct=\"${pct:-}\""
  echo "pg_rate=\"$rate\""
  echo "pg_eta=\"${eta:-}\""
  echo "pg_updated=\"$now\""
} > "$TMP"
mv "$TMP" "$OUT"
