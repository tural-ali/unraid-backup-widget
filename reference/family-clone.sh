#!/bin/bash
# Clone family-archive to Google Drive.
#
# A CLONE, not a backup: Drive mirrors the archive, deletions included. The
# versioned protection for family-archive is the Duplicacy backup on Dropbox;
# nothing here changes that. What this script guards against is one specific
# failure: /mnt/user is FUSE, so a stopped array or a dead shfs makes the whole
# tree read as absent, and a naive sync would delete 3.3 TiB from Drive to
# match. Bad sectors and unreadable files are NOT a risk here - the file is
# still listed, rclone fails to read it and leaves the Drive copy alone.
#
# The rule: a deletion propagates to Drive only if the file went into a bin.
# The old Daddy Cull moved culls to .culled/ and recorded them in cull.db. The
# new one (tower-cull-next) records every file it bins in library.db and only
# counts it gone once its grace period has ended and the file is deleted from
# disk; until then Drive keeps its copy, quietly, because the file can still be
# restored. Lightroom's deletions arrive over SMB and Samba's recycle module
# diverts them into .Recycle.Bin/. A disk dropping out, a broken mount, a bad
# cable - none of those put anything in a bin, so none of them can remove
# anything from Drive. Absences that no bin explains are left on Drive and
# reported, nothing more.
#
# Additions and changes always upload. The clone never goes stale waiting on
# a decision about deletions.
#
# Usage:  family-clone.sh [sync|plan|status|approve]
#   plan               list what a sync would delete or keep, changing nothing
#   CLONE_NO_NOTIFY=1  suppress Unraid notifications (for tests)

set -uo pipefail

R=/mnt/user/appdata/rclone
C="$R/bin/rclone --config $R/config/rclone.conf"
ARCHIVE=/mnt/user/family-archive
DEST=Gdrive:family-archive
CULLDB=/mnt/user/appdata/tower-cull/cull.db
# The new app's catalogue. Read from the cache pool directly, as its containers
# mount it, because SQLite's WAL locking is not reliable through shfs.
NEXTDB=/mnt/cache/appdata/tower-cull-next/library.db
RECYCLE=$ARCHIVE/.Recycle.Bin

STATE=$R/clone-state
PENDING=$STATE/unexplained.txt      # absences no bin accounts for
HELD=$STATE/held-in-bin.txt         # absences the new app can still restore
NEXT_GONE=$STATE/next-purged.list   # scratch: files the new app has deleted
NEXT_HELD=$STATE/next-held.list     # scratch: files the new app still holds
LOG=$R/logs/family-clone.log

CANARY=$ARCHIVE/.clone-canary
CANARY_TEXT="family-archive clone canary - do not delete"

# Bins and housekeeping never go to Drive. .live-photos is deliberately NOT
# here: the clone is meant to be complete, and that exclusion belonged to the
# retired class mirrors.
EXCLUDES=(
  --exclude "/.culled/**"
  --exclude "/.Recycle.Bin/**"
  --exclude "/.clone-canary"
  --exclude "/.duplicacy"
  --exclude "/.tmp.driveupload/**"
  --exclude ".DS_Store"
  --exclude "._*"
  --exclude "/.osxphotos_export.db*"
  # Jellyfin "skip this folder" markers. Local-only metadata that icloud-graduate
  # creates and removes as day folders gain or lose video, so every graduation
  # showed up as an unexplained deletion. The clone is a browsable mirror, not
  # the restore path (Duplicacy on Dropbox is), so Drive has no use for them.
  --exclude ".ignore"
)

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

notify() {  # $1 = severity, $2 = subject, $3 = description
  [ -n "${CLONE_NO_NOTIFY:-}" ] && return 0
  /usr/local/emhttp/webGui/scripts/notify \
    -e "family-archive clone" -s "$2" -d "$3" -i "$1" >/dev/null 2>&1
}

die() { log "REFUSED: $*"; notify alert "Clone refused" "$*"; exit 1; }

# ---------------------------------------------------------------- preflight
# Only the mount itself is checked. A broken mount is the one failure that
# makes every later comparison meaningless, and it is also the one that no
# amount of culling can produce.
preflight() {
  mountpoint -q /mnt/user || die "/mnt/user is not a mountpoint - array down or shfs failed"
  [ -f "$CANARY" ] && grep -qF "$CANARY_TEXT" "$CANARY" \
    || die "canary missing or altered at $CANARY"
}

# ------------------------------------------------------- new app records
# library.db keeps each Bin batch as a JSON plan whose files carry the path
# relative to the archive root - the same form rclone reports - and a phase.
# A file is gone for good once its phase is purged (or absent_after_intent: its
# deletion was recorded and it is no longer there). A file in a batch that is
# still in the Bin, being moved, or waiting out its grace period is held. Held
# wins over gone, so a path deleted once and binned again later is kept. An
# sqlite failure leaves both lists empty: nothing is vouched for, and binned
# files show up as unexplained - the safe direction.
load_next_records() {
  : > "$NEXT_GONE"; : > "$NEXT_HELD"
  [ -f "$NEXTDB" ] || { log "new app catalogue not found at $NEXTDB - its deletions stay unexplained"; return 0; }
  sqlite3 -readonly "$NEXTDB" "select distinct json_extract(f.value,'\$.original') from file_plans p, json_each(p.body,'\$.files') f where json_extract(f.value,'\$.phase') in ('purged','absent_after_intent');" \
      > "$NEXT_GONE" 2>/dev/null \
    && sqlite3 -readonly "$NEXTDB" "select distinct json_extract(f.value,'\$.original') from file_plans p, json_each(p.body,'\$.files') f where json_extract(p.body,'\$.state') in ('quarantining','moving','bin','purging','restoring') and json_extract(f.value,'\$.phase') not in ('purged','absent_after_intent','restored');" \
      > "$NEXT_HELD" 2>/dev/null \
    || { log "could not read $NEXTDB - its deletions stay unexplained"; : > "$NEXT_GONE"; : > "$NEXT_HELD"; }
}

is_held() { grep -Fxq -- "$1" "$NEXT_HELD"; }

# ----------------------------------------------------------- is_accounted
# $1 = archive-relative path that is absent locally. Succeeds if a bin holds it.
#
# The recycle module keeps the directory tree, so the check is a direct stat.
# cull.db stores container-internal paths (/archive/..., /disks/disk1/...);
# comparing from the first 4-digit year segment makes both sides agree
# regardless of prefix.
is_accounted() {
  local rel="$1" q n
  [ -e "$RECYCLE/$rel" ] && return 0
  grep -Fxq -- "$rel" "$NEXT_GONE" && return 0
  # Exact suffix match on "/<rel>" so IMG.JPG cannot satisfy XIMG.JPG, and no
  # LIKE wildcards, because _ is in half the filenames. An sqlite failure
  # yields an empty count, which reads as unaccounted - the safe direction.
  q=$(printf "%s" "/$rel" | sed "s/'/''/g")
  n=$(sqlite3 "$CULLDB" "select count(*) from culled where substr(original_path, -length('$q')) = '$q';" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] 2>/dev/null
}

# ------------------------------------------------------------------- plan
# What would rclone delete from Drive? Ask without letting it act.
planned_deletes() {
  $C sync "$ARCHIVE" "$DEST" "${EXCLUDES[@]}" --dry-run --log-level NOTICE 2>&1 \
    | sed -n 's/^.*NOTICE: \(.*\): Skipped delete as --dry-run.*$/\1/p' | sort -u
}

# Sort what rclone would delete into three lists: vouched for by a bin (ok),
# still restorable in the new app's Bin (held), and unexplained.
classify() {
  local rel
  ok=(); held=(); unexplained=()
  load_next_records
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if is_held "$rel"; then held+=("$rel")
    elif is_accounted "$rel"; then ok+=("$rel")
    else unexplained+=("$rel"); fi
  done < <(planned_deletes)
}

cmd_plan() {
  preflight
  mkdir -p "$STATE"
  classify
  echo "would delete from Drive (a bin vouches): ${#ok[@]}"
  [ "${#ok[@]}" -gt 0 ] && printf '  %s\n' "${ok[@]}" | head -50
  echo "kept on Drive, still restorable in the Bin: ${#held[@]}"
  [ "${#held[@]}" -gt 0 ] && printf '  %s\n' "${held[@]}" | head -20
  echo "kept on Drive, unexplained: ${#unexplained[@]}"
  [ "${#unexplained[@]}" -gt 0 ] && printf '  %s\n' "${unexplained[@]}" | head -20
  return 0
}

cmd_sync() {
  # Serialise. The daily cron can fire while a previous run is still going (the
  # first full clone took five days), and two rclones on the same destination
  # would fight: one uploading while the other computes deletions from a listing
  # the first is still changing. Non-blocking on purpose - a tick that finds work
  # already in progress exits quietly rather than queueing up behind it.
  mkdir -p "$STATE"
  exec 9>"$STATE/clone.lock"
  if ! flock -n 9; then
    log "another clone is already running - this invocation exits"
    exit 0
  fi

  preflight
  mkdir -p "$STATE"

  # 1. Additions and changes, unconditionally.
  log "copy $ARCHIVE -> $DEST"
  $C copy "$ARCHIVE" "$DEST" "${EXCLUDES[@]}" \
      --transfers 8 --checkers 16 \
      --bwlimit "00:00,off 08:00,12M 23:00,off" \
      --log-file "$LOG" --log-level INFO --stats 5m --stats-one-line \
    || log "copy finished with errors (see above) - continuing to deletions"

  # 2. Deletions, only where a bin vouches for them.
  local ok held unexplained
  classify

  if [ "${#ok[@]}" -gt 0 ]; then
    printf '%s\n' "${ok[@]}" > "$STATE/accounted.txt"
    log "deleting ${#ok[@]} binned paths from Drive"
    $C delete "$DEST" --files-from "$STATE/accounted.txt" --log-file "$LOG" --log-level INFO \
      || log "delete finished with errors"
  fi

  if [ "${#held[@]}" -gt 0 ]; then
    printf '%s\n' "${held[@]}" > "$HELD"
    log "kept on Drive: ${#held[@]} files still in the Bin or its grace period - see $HELD"
  else
    rm -f "$HELD"
  fi

  if [ "${#unexplained[@]}" -gt 0 ]; then
    printf '%s\n' "${unexplained[@]}" > "$PENDING"
    log "KEPT on Drive: ${#unexplained[@]} absences no bin explains - see $PENDING"
    notify warning "Clone: ${#unexplained[@]} unexplained absences kept on Drive" \
      "${#unexplained[@]} files are gone locally but in no cull bin, so they were NOT deleted from Drive. List: $PENDING. If they are renames or shell deletions you recognise: family-clone.sh approve"
  else
    rm -f "$PENDING"
    log "done: ${#ok[@]} deletions propagated, nothing unexplained"
  fi
  /mnt/user/appdata/scripts/hc-ping.sh family-clone up "sync done: ${#ok[@]} deletions, ${#held[@]} held in Bin, ${#unexplained[@]} unexplained"
}

# Delete exactly the currently listed unexplained paths, now. Consuming the
# list immediately is what stops an approval from leaking onto a later,
# different set of absences.
cmd_approve() {
  [ -s "$PENDING" ] || { echo "nothing pending"; exit 0; }
  preflight
  local n; n=$(wc -l < "$PENDING")
  log "operator approved $n unexplained deletions"
  $C delete "$DEST" --files-from "$PENDING" --log-file "$LOG" --log-level INFO \
    && { rm -f "$PENDING"; echo "deleted $n paths from Drive"; } \
    || echo "delete reported errors - list retained at $PENDING"
}

cmd_status() {
  echo "archive : $ARCHIVE"
  echo "dest    : $DEST"
  echo "recycle : $RECYCLE $([ -d "$RECYCLE" ] && echo present || echo ABSENT)"
  [ -s "$HELD" ] && echo "held    : $(wc -l < "$HELD") files kept on Drive while still restorable in the Bin"
  if [ -s "$PENDING" ]; then
    echo "--- unexplained absences kept on Drive: $(wc -l < "$PENDING")"
    head -20 "$PENDING"; [ "$(wc -l < "$PENDING")" -gt 20 ] && echo "  ..."
  else
    echo "pending : none"
  fi
}

case "${1:-status}" in
  sync)    cmd_sync ;;
  plan)    cmd_plan ;;
  approve) cmd_approve ;;
  status)  cmd_status ;;
  *) echo "usage: $0 [sync|plan|status|approve]"; exit 1 ;;
esac
