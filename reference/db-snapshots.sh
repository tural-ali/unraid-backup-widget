#!/bin/bash
# Consistent copies of the live SQLite databases under appdata, taken by
# backup.sh right before the nightly appdata leg. Added 2026-09-30.
#
# Duplicacy reads a file start to end while the app keeps writing to it, and a
# WAL-mode database is two files that must agree. A copy taken that way can open
# as "database disk image is malformed" or silently lose the last transactions,
# so prefs/appdata/filters excludes the live files and the appdata repo holds
# these snapshots instead.
#
# Restore: stop the container, copy backups/live-db/<name>.db over the live path
# below, delete any -wal and -shm beside it, fix ownership, start the container.
#
# VACUUM INTO reads inside a single transaction, so it is consistent against a
# running writer (the online-backup API restarts every time the writer commits,
# and Home Assistant commits every few seconds). It runs as the database's owner:
# SQLite may create -wal/-shm beside the live file, and root-owned ones would
# lock a uid-99 app out of its own database.
set -u
OUT=/mnt/user/appdata/backups/live-db

# name|live database
DBS="
easygerman-progress|/mnt/user/appdata/easygerman-mirror/progress/progress.db
easygerman-content|/mnt/user/appdata/easygerman-mirror/data/site.db
tower-cull-next|/mnt/user/appdata/tower-cull-next/library.db
uptime-kuma|/mnt/user/appdata/uptime-kuma/kuma.db
homeassistant|/mnt/user/appdata/homeassistant/config/home-assistant_v2.db
jellyfin|/mnt/user/appdata/Jellyfin/data/jellyfin.db
scrutiny|/mnt/user/appdata/scrutiny/config/scrutiny.db
"

# Root-only. Until 2026-11-12 this directory was root:users 0770 so each
# database owner could write its VACUUM INTO output straight into it, and root
# then checked and renamed that file. Anything running as uid 99 (most
# containers) could swap the file for a symlink between those steps. Now each
# copy is written into a private work directory owned by that database owner,
# root takes the directory back before looking at what is inside, and only a
# verified regular file is installed here.
mkdir -p "$OUT"
chown root:root "$OUT"
chmod 0750 "$OUT"
find "$OUT" -maxdepth 1 \( -name '.*.db.tmp' -o -name '.*.db.new' \) -delete

work=
cleanup() { [ -n "$work" ] && rm -rf -- "$work"; work=; }
trap cleanup EXIT

rc=0
while IFS='|' read -r name src; do
  [ -n "$name" ] || continue
  cleanup
  if [ ! -s "$src" ]; then
    echo "db-snapshots: $name: $src missing or empty"; rc=1; continue
  fi
  uid=$(stat -c %u "$src"); gid=$(stat -c %g "$src")
  # On the array, not /tmp: /tmp is RAM and some of these are several GB.
  if ! work=$(mktemp -d "$(dirname "$OUT")/.live-db-work.XXXXXX"); then
    echo "db-snapshots: $name: cannot create work directory"; work=; rc=1; continue
  fi
  chown "$uid:$gid" "$work"
  tmp="$work/$name.db"
  # the path is ours, not user input, but keep quotes out of the SQL anyway
  case "$tmp" in *\'*) echo "db-snapshots: $name: bad path"; rc=1; continue;; esac
  if ! setpriv --reuid="$uid" --regid="$gid" --clear-groups \
       sqlite3 -bail "file:$src?mode=ro" ".timeout 60000" "VACUUM INTO '$tmp'"; then
    echo "db-snapshots: $name: VACUUM INTO failed"; rc=1; continue
  fi
  # Take the directory back first: once root owns it at 0700, the database
  # owner can no longer replace what is inside, so the checks below hold.
  chown root:root "$work"; chmod 0700 "$work"
  if [ ! -f "$tmp" ] || [ -L "$tmp" ]; then
    echo "db-snapshots: $name: output is not a regular file"; rc=1; continue
  fi
  chk=$(sqlite3 "$tmp" "PRAGMA quick_check" 2>&1)
  if [ "$chk" != "ok" ]; then
    echo "db-snapshots: $name: quick_check: $chk"; rc=1; continue
  fi
  if ! install -m 0640 -o root -g root "$tmp" "$OUT/.$name.db.new" ||
     ! mv -f "$OUT/.$name.db.new" "$OUT/$name.db"; then
    echo "db-snapshots: $name: install failed"; rm -f "$OUT/.$name.db.new"; rc=1; continue
  fi
  echo "db-snapshots: $name: $(stat -c %s "$OUT/$name.db") bytes"
done <<< "$DBS"
exit $rc
