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
BASE=/mnt/user/appdata/backups
ANCHOR=.db-snapshots-anchor
OUT=live-db   # relative to BASE

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

# Hardened 2026-11-12. appdata itself is nobody:users 0777, so anything running
# as uid 99 (most containers) can rename entries in it, this directory
# included, and Unraid ships fs.protected_hardlinks=0 and protected_symlinks=0.
# So root never follows a path it has not pinned:
#   - It enters BASE once and works relative to that directory from then on,
#     after proving it is the real one: root-owned, not writable by anyone
#     else, holding a root-owned marker only root can have put there. Created
#     by hand: install -m 0600 -o root -g root /dev/null $BASE/$ANCHOR
#   - Each copy is written inside a root-owned work directory, into an
#     output directory that belongs to the database owner and is 0700, so no
#     other account can list it, read the copy or plant a link for the owner's
#     sqlite3 to follow. Afterwards root takes the output directory back
#     (root:root 0700) before looking inside.
#   - Root keeps a copy only if it is a single-link regular file owned by that
#     database owner, copies it to a root-only file first and checks that copy
#     with immutable=1, so SQLite never opens a -wal, -shm or -journal there.
# Until this change live-db was root:users 0770 and root checked and renamed a
# file the database owner could still swap.
if ! cd "$BASE" 2>/dev/null; then
  echo "db-snapshots: cannot enter $BASE"; exit 1
fi
if [ "$(stat -c %u .)" != 0 ] || [ -n "$(find . -maxdepth 0 -perm /022)" ] ||
   [ ! -f "$ANCHOR" ] || [ -L "$ANCHOR" ] || [ "$(stat -c %u -- "$ANCHOR")" != 0 ]; then
  echo "db-snapshots: $BASE is not the root-owned directory holding $ANCHOR; refusing"; exit 1
fi
if [ -L "$OUT" ]; then
  echo "db-snapshots: $BASE/$OUT is a symlink; refusing"; exit 1
fi
mkdir -p "$OUT"
chown root:root "$OUT"
chmod 0750 "$OUT"
find "$OUT" -maxdepth 1 \( -name '.*.db.tmp' -o -name '.*.db.new' \) -delete
find . -maxdepth 1 -name '.live-db-work.*' -type d -exec rm -rf -- {} +

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
  if ! work=$(mktemp -d -p . .live-db-work.XXXXXX); then
    echo "db-snapshots: $name: cannot create work directory"; work=; rc=1; continue
  fi
  # BASE is world-readable, so others can see this name. The work directory
  # stays root-owned; others may only pass through it (0711, and only when the
  # owner is not root) into out/, which is the owner's and 0700. SQLite needs
  # to create a journal next to the copy, so out/ must be writable by the owner.
  out="$work/out"
  if ! { mkdir -m 0700 -- "$out" && chown "$uid:$gid" -- "$out"; }; then
    echo "db-snapshots: $name: cannot create output directory"; rc=1; continue
  fi
  [ "$uid" = 0 ] || chmod 0711 "$work"
  tmp="$out/$name.db"
  # the path is ours, not user input, but keep quotes out of the SQL anyway
  case "$tmp" in *\'*) echo "db-snapshots: $name: bad path"; rc=1; continue;; esac
  if ! ( umask 077
         setpriv --reuid="$uid" --regid="$gid" --clear-groups \
           sqlite3 -bail "file:$src?mode=ro" ".timeout 60000" "VACUUM INTO '$tmp'" ); then
    echo "db-snapshots: $name: VACUUM INTO failed"; rc=1; continue
  fi
  # Take out/ back first: a process of the owner's uid that is already inside
  # it could otherwise still add, remove or rename entries. Once it is
  # root:root 0700 nobody else can, and the checks below hold.
  chown root:root -- "$out"; chmod 0700 -- "$out" "$work"
  if [ ! -f "$tmp" ] || [ -L "$tmp" ] ||
     [ "$(stat -c '%u %h' -- "$tmp")" != "$uid 1" ]; then
    echo "db-snapshots: $name: output is not a single-link regular file owned by uid $uid"; rc=1; continue
  fi
  new="$OUT/.$name.db.new"
  if ! install -m 0600 -o root -g root -- "$tmp" "$new"; then
    echo "db-snapshots: $name: copy failed"; rm -f -- "$new"; rc=1; continue
  fi
  chk=$(sqlite3 "file:$new?mode=ro&immutable=1" "PRAGMA quick_check" 2>&1)
  if [ "$chk" != "ok" ]; then
    echo "db-snapshots: $name: quick_check: $chk"; rm -f -- "$new"; rc=1; continue
  fi
  chmod 0640 "$new"
  if ! mv -f -- "$new" "$OUT/$name.db"; then
    echo "db-snapshots: $name: install failed"; rm -f -- "$new"; rc=1; continue
  fi
  echo "db-snapshots: $name: $(stat -c %s "$OUT/$name.db") bytes"
done <<< "$DBS"
exit $rc
