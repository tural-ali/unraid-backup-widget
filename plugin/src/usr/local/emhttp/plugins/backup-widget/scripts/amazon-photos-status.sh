#!/bin/bash
# Amazon Photos backup state for the tile and the overview page.
#
# The uploader (appdata/amazon-photos) copies every family-archive photo to
# Amazon Photos and keeps a ledger of each file it has confirmed there. This
# reads that ledger and its status.json, both local, so it is cheap enough to
# run every minute and makes no call to Amazon.
#
#   ap_state          running | idle
#   ap_eligible       photos in the archive that belong on Amazon (last full count)
#   ap_done           of those, confirmed on Amazon
#   ap_uploaded       files this backup sent itself (the rest Amazon already had)
#   ap_problems       files whose last attempt failed; retried every run
#   ap_trashed        stray screenshots moved to Amazon's trash, still restorable
#   ap_last_end       end of the last upload run, epoch
#   ap_last_exit      its exit code
#   ap_login_expires  when the saved Amazon cookies expire, epoch (0 = unknown)
#   ap_share          the share it copies from (its compose.yaml /archive mount)
#
# Writes /var/local/emhttp/amazon-photos.ini. Absent install = no file, and the
# renderers then show nothing rather than a dead "0 of 0".
set -u
AP=/mnt/user/appdata/amazon-photos
OUT=/var/local/emhttp/amazon-photos.ini
DB=$AP/state/ledger.db
ST=$AP/state/status.json

[ -f "$DB" ] && [ -f "$ST" ] || { rm -f "$OUT"; exit 0; }

state=idle
docker ps --filter name='^amazon-photos-sync$' --format '{{.Names}}' 2>/dev/null | grep -q . && state=running

# -readonly: the uploader holds this database open in WAL mode
q() { sqlite3 -readonly "$DB" "$1" 2>/dev/null; }
ledger_done=$(q "SELECT count(*) FROM files WHERE status IN ('uploaded','exists')")
uploaded=$(q "SELECT count(*), coalesce(sum(size),0) FROM files WHERE status='uploaded'")
problems=$(q "SELECT count(*) FROM files WHERE status NOT IN ('uploaded','exists')")
trashed=$(q "SELECT count(*) FROM trashed WHERE restored_at IS NULL")

eligible=$(jq -r '.photos.eligible // 0' "$ST" 2>/dev/null)
eligible_done=$(jq -r '.photos.eligible_done // 0' "$ST" 2>/dev/null)
counted=$(jq -r '.photos.counted // ""' "$ST" 2>/dev/null)
last_end=$(jq -r '.runs.upload.ended // ""' "$ST" 2>/dev/null)
last_exit=$(jq -r '.runs.upload.exit // ""' "$ST" 2>/dev/null)
# The share the uploader reads, from its compose file's "<share>:/archive" mount,
# so the overview puts Amazon in the right row without a setting of its own.
share=$(sed -n 's#^[[:space:]]*-[[:space:]]*/mnt/user/\([^/:]*\):/archive\(:ro\)\{0,1\}[[:space:]]*$#\1#p' "$AP/compose.yaml" 2>/dev/null | head -1)
# only the expiry line: .env also holds the cookies themselves
login_expires=$(sed -n 's/^AP_COOKIES_EXPIRES=//p' "$AP/.env" 2>/dev/null)

# The exact figure comes from the last complete walk of the archive. During a
# run the ledger is the live one; it can count photos since removed from the
# archive, so it is capped rather than trusted past the total.
if [ "$state" = running ] || [ -z "$counted" ] || [[ "$last_end" > "$counted" ]]; then
  done=${ledger_done:-0}
else
  done=${eligible_done:-0}
fi
[ "${eligible:-0}" -gt 0 ] && [ "$done" -gt "$eligible" ] && done=$eligible

epoch() { [ -n "$1" ] && date -d "$1" +%s 2>/dev/null || echo 0; }

tmp=$OUT.tmp
{
  echo "ap_state=\"$state\""
  echo "ap_eligible=\"${eligible:-0}\""
  echo "ap_done=\"$done\""
  echo "ap_uploaded=\"${uploaded%%|*}\""
  echo "ap_uploaded_bytes=\"${uploaded##*|}\""
  echo "ap_problems=\"${problems:-0}\""
  echo "ap_trashed=\"${trashed:-0}\""
  echo "ap_last_end=\"$(epoch "$last_end")\""
  echo "ap_last_exit=\"$last_exit\""
  echo "ap_login_expires=\"$(epoch "$login_expires")\""
  echo "ap_share=\"${share:-family-archive}\""
  echo "ap_updated=\"$(date +%s)\""
} > "$tmp" && mv -f "$tmp" "$OUT"
