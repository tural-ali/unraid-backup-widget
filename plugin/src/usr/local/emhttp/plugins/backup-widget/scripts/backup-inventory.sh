#!/bin/bash
# Per-dataset size and file count for the backup overview page.
#
# Separate from duplicacy-coverage.sh because it touches only the local
# filesystem - no cloud calls, no credentials - and because a slow or throttled
# cloud must never stop the page from being able to state how much data exists.
#
# du on the array is metadata-only and takes seconds even for 1.6 TB, so every
# 6h is comfortable. The page reads the cached values; it never walks anything
# itself, or loading the dashboard would stat 30k files.
#
# Output: /var/local/emhttp/backup-inventory.ini
set -u
exec 9>/var/run/backup-widget-inventory.lock
flock -n 9 || exit 0
# Configuration, shared with the settings page and the renderers. KEY="value" so
# this file is both parse_ini_file-able and source-able - one file, no second
# parser to drift. Absent config falls back to the defaults below.
CONF=/boot/config/plugins/backup-widget/config
[ -f "$CONF" ] && . "$CONF"
: "${DUP_DIR:=/mnt/user/appdata/duplicacy}"
: "${RCLONE_DIR:=/mnt/user/appdata/rclone}"

OUT=/var/local/emhttp/backup-inventory.ini
TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

# Datasets come from the config: whatever has a Duplicacy target or is mirrored.
SHARES=$(
  { for e in ${BW_SETS:-}; do echo "${e%%:*}"; done
    for m in ${BW_MIRRORED:-}; do echo "$m"; done
    for p in ${BW_PAUSED:-}; do echo "$p"; done
  } | awk 'NF' | sort -u | tr '\n' ' '
)
[ -n "$(echo $SHARES | tr -d ' ')" ] || SHARES="raw-photos videos paperless immich appdata"

: > "$TMP"
total=0
for s in $SHARES; do
  d="/mnt/user/$s"
  [ -d "$d" ] || continue
  bytes=$(du -sb "$d" 2>/dev/null | cut -f1)
  files=$(find "$d" -type f ! -name '.*' 2>/dev/null | wc -l)
  key=$(echo "$s" | tr -- '-' '_')
  echo "inv_${key}_bytes=\"${bytes:-0}\"" >> "$TMP"
  echo "inv_${key}_files=\"${files:-0}\"" >> "$TMP"
  total=$(( total + ${bytes:-0} ))
done
echo "inv_total_bytes=\"$total\"" >> "$TMP"
echo "inv_updated=\"$(date '+%s')\"" >> "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
