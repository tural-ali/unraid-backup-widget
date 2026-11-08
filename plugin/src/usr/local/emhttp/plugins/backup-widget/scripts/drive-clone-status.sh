#!/bin/bash
# Google Drive clone state for the tile and the overview page.
#
# family-clone.sh (in RCLONE_DIR) mirrors one share to Google Drive with rclone
# every night. It is a clone, not a versioned backup, and it never deletes from
# Drive what no cull bin vouches for. This reads only its own log and state
# files, both local, so it makes no call to Drive.
#
#   dc_share        the share being cloned (ARCHIVE= in the script)
#   dc_dest         the rclone destination (DEST= in the script)
#   dc_state        running | idle
#   dc_last_start   start of the last run that got as far as copying, epoch
#   dc_last_end     end of that run, epoch (0 = it has not finished)
#   dc_result       ok | errors | none   (errors = some files failed to copy or delete)
#   dc_last_ok      end of the last run that finished without errors, epoch
#   dc_refused_at   last time preflight refused to run (mount or canary), epoch
#   dc_refused      what it said
#   dc_deleted      deletions the last run propagated to Drive
#   dc_held         files kept on Drive because they are still restorable in a Bin
#   dc_unexplained  absences no bin explains, kept on Drive for review
#
# Writes /var/local/emhttp/drive-clone.ini. No clone script = no file, and the
# renderers then treat Google like any other Duplicacy-only target.
set -u
: "${RCLONE_DIR:=/mnt/user/appdata/rclone}"
CONF=/boot/config/plugins/backup-widget/config
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

SCRIPT=$RCLONE_DIR/family-clone.sh
STATE=$RCLONE_DIR/clone-state
LOG=$RCLONE_DIR/logs/family-clone.log
OUT=/var/local/emhttp/drive-clone.ini

[ -f "$SCRIPT" ] || { rm -f "$OUT"; exit 0; }

# The script's own settings, so a change of share or remote follows by itself.
setting() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$SCRIPT" | head -1; }
archive=$(setting ARCHIVE)
dest=$(setting DEST)
share=${archive#/mnt/user/}

# Running = some process holds the clone's lock file open. fuser only looks;
# taking the flock ourselves could make a starting run think another is going
# and skip the night.
state=idle
fuser -s "$STATE/clone.lock" 2>/dev/null && state=running

# The script's own lines are "YYYY-MM-DD HH:MM:SS msg"; rclone's are
# "YYYY/MM/DD ...". A run begins with "copy ..." and ends with "done:" or
# "KEPT on Drive:". A refusal happens before "copy", so it is tracked apart.
summary=$(awk '
  /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} / {
    ts = $1 " " $2; msg = substr($0, 21)
    if (msg ~ /^copy /)                         { start = ts; end = ""; err = 0; del = 0 }
    else if (msg ~ /finished with errors/)      { err = 1 }
    else if (msg ~ /^deleting [0-9]+ binned/)   { split(msg, a, " "); del = a[2] }
    else if (msg ~ /^(done:|KEPT on Drive:)/)   { end = ts; if (!err) ok = ts }
    else if (msg ~ /^REFUSED: /)                { rts = ts; rmsg = substr(msg, 10) }
  }
  END {
    gsub(/"/, "", rmsg)
    printf "%s|%s|%s|%s|%s|%s|%s\n", start, end, (start == "" ? "none" : (err ? "errors" : "ok")), ok, del + 0, rts, rmsg
  }' "$LOG" 2>/dev/null)
IFS='|' read -r start end result last_ok deleted refused_at refused <<< "$summary"

epoch() { [ -n "$1" ] && date -d "$1" +%s 2>/dev/null || echo 0; }
count() { [ -s "$1" ] && wc -l < "$1" || echo 0; }

tmp=$OUT.tmp
{
  echo "dc_share=\"$share\""
  echo "dc_dest=\"$dest\""
  echo "dc_state=\"$state\""
  echo "dc_last_start=\"$(epoch "$start")\""
  echo "dc_last_end=\"$(epoch "$end")\""
  echo "dc_result=\"${result:-none}\""
  echo "dc_last_ok=\"$(epoch "$last_ok")\""
  echo "dc_refused_at=\"$(epoch "$refused_at")\""
  echo "dc_refused=\"$refused\""
  echo "dc_deleted=\"${deleted:-0}\""
  echo "dc_held=\"$(count "$STATE/held-in-bin.txt")\""
  echo "dc_unexplained=\"$(count "$STATE/unexplained.txt")\""
  echo "dc_updated=\"$(date +%s)\""
} > "$tmp" && mv -f "$tmp" "$OUT"
