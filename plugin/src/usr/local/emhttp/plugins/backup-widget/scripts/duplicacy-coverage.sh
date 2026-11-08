#!/bin/bash
# Builds the per-repo / per-storage coverage picture for the dashboard tile.
# Each check hits the cloud and takes seconds, so this runs every 6h (and after
# the nightly run) rather than every minute like the progress script.
# Output: /var/local/emhttp/duplicacy-coverage.ini
#
# Two backup modes can target Dropbox, and the tile has to distinguish them:
#
#   Duplicacy storages      Coverage = newest committed snapshot, found with
#                           `duplicacy list`. This includes Dropbox repositories.
#   Dropbox rclone mirror   There are no snapshots to list. Coverage is measured
#                           by comparing remote and local bytes with matching filters.
#
# BW_SETS owns Duplicacy targets. BW_MIRRORED independently owns plain mirrors.
set -u
# Configuration, shared with the settings page and the renderers. KEY="value" so
# this file is both parse_ini_file-able and source-able - one file, no second
# parser to drift. Absent config falls back to the defaults below.
CONF=/boot/config/plugins/backup-widget/config
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
: "${DUP_DIR:=/mnt/user/appdata/duplicacy}"
: "${RCLONE_DIR:=/mnt/user/appdata/rclone}"

D=$DUP_DIR
R=$RCLONE_DIR
OUT=/var/local/emhttp/duplicacy-coverage.ini
LOCK=/var/run/backup-widget-coverage.lock
exec 9>"$LOCK"
flock -n 9 || exit 0

TMP="${OUT}.$$"
TOT_TMP=""
cleanup() {
  [ -n "${TMP:-}" ] && rm -f "$TMP"
  [ -n "${TOT_TMP:-}" ] && rm -f "$TOT_TMP"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "$D/secret.env"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
export SSL_CERT_FILE=$R/tls/ca-bundle.crt
export DUPLICACY_GDRIVE_GCD_TOKEN=$D/tokens/gcd-token.json
DUPLICACY_DROPBOX_DROPBOX_TOKEN=$(cat "$D/tokens/dropbox-token.json" 2>/dev/null)
export DUPLICACY_DROPBOX_DROPBOX_TOKEN
# The on-array paperless copy reuses the gdrive key rather than introducing a
# secret whose only copy would live on the machine it is protecting.
export DUPLICACY_LOCAL_PASSWORD="${DUPLICACY_GDRIVE_PASSWORD:-}"

# repo:duplicacy-storages. Dropbox can hold isolated Duplicacy repositories while
# BW_MIRRORED remains reserved for any plain rclone mirrors.
SETS="${BW_SETS:-paperless:gdrive,dropbox,local appdata:gdrive,dropbox immich:gdrive,dropbox}"

repo_root() {
  local repo="$1" entry
  for entry in ${BW_REPO_ROOTS:-}; do
    if [ "${entry%%=*}" = "$repo" ]; then
      printf '%s' "${entry#*=}"
      return
    fi
  done
  printf '/mnt/user/%s' "$repo"
}

# Shares the rclone mirror covers. Must match SHARES in rclone-dropbox-sync.sh.
MIRRORED="${BW_MIRRORED:-}"

# Same exclusions the sync applies, so a filtered-out file cannot make a
# complete mirror look short of 100%.
EX=(--exclude '.DS_Store' --exclude '._*' --exclude '.duplicacy/**' --exclude '**/@eaDir/**')

# --- transient cloud failures ------------------------------------------------
# A throttled cloud can answer its API with an HTML error page instead of JSON.
# rclone reports that as "invalid character '<'", and Duplicacy as "Failed to
# load the ... storage" or a 429. None of that means the backup is missing - it
# is only listing that is refused. (Learned on mail.ru, dropped 2026-11-07, whose
# WebDAV bridge also turned the throttle into 405 "Method not allowed".)
#
# The probes below used to discard stderr, so a throttled read was
# indistinguishable from "nothing is there" and the tile recorded a hard gap
# ("-", "seed0.0") that then sat on the dashboard until the next 6h run. That is
# a false alarm on a backup that is in fact current, which is the worst possible
# direction for this tile to be wrong in.
#
# So: recognise the throttle, retry it, and if it still will not answer, carry
# the previous run's value forward rather than inventing a gap. A clean empty
# answer - no error, just no snapshots - is still reported as "-", because that
# one is a real observation.
transient_err() {
  printf '%s' "$1" | grep -qiE "invalid character '<'|Method not allowed|Failed to load the .*storage|429 |too many requests|rate limit"
}

# Previous value for one storage prefix in a repo's cached cell, e.g.
#   prev_seg paperless m  ->  r675@30/08 19:15
# Reads $OUT, which still holds the last run until the new file is moved into
# place at the end of this script.
prev_seg() {
  local key
  key=$(printf '%s' "$1" | tr -- '-' '_')
  grep -oE "^cov_${key}=\"[^\"]*\"" "$OUT" 2>/dev/null | head -1 | cut -d'"' -f2 \
    | tr '|' '\n' | grep -E "^$2:" | head -1 | cut -d: -f2-
}

# Duplicacy writes a snapshot only when a backup finishes, so a first seed is
# invisible to `duplicacy list` - it looks identical to "nothing has ever run".
# Detect the live process by its working directory and report the percentage.
# shellcheck disable=SC2012  # backup-YYYY-MM-DD.log names only
current_log() { ls -t "$D"/logs/backup-*.log 2>/dev/null | head -1; }

seed_pct() {
  local repo="$1" st="$2" pid cwd pct log
  log=$(current_log)
  [ -n "$log" ] || return 1
  local pat="duplicacy backup -storage $st"
  [ "$st" = gdrive ] && pat="duplicacy backup -stats"
  for pid in $(pgrep -f "$pat" 2>/dev/null); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    [ "$cwd" = "/mnt/user/$repo" ] || continue
    # The percentage must come from THIS repo's section of the log, not simply the
    # last percentage in it. The log is shared by every repo in a run, and an
    # out-of-band job writing its own log left the widget reporting 95% for a
    # transfer that was actually at 38%.
    pct=$(awk -v r="$repo" '
      index($0, "=== " r " ") == 1 { inrepo = 1; last = ""; next }
      /^=== / { inrepo = 0 }
      inrepo && match($0, /[0-9]+\.[0-9]%$/) { last = substr($0, RSTART, RLENGTH) }
      END { print last }
    ' "$log")
    [ -n "$pct" ] || return 1
    printf '%s' "$pct"
    return 0
  done
  return 1
}

# bytes of a path as rclone sees it, honouring the sync's filters
# shellcheck disable=SC2086  # $extra holds zero or more flags, split on purpose
rc_bytes() {
  local target="$1" extra="${2:-}"
  timeout 300 "$R/bin/rclone" --config "$R/config/rclone.conf" size "$target" \
    "${EX[@]}" $extra --json 2>/dev/null \
    | grep -oE '"bytes":[0-9]+' | head -1 | cut -d: -f2
}

# --- class mirrors -----------------------------------------------------------
# One dataset can have a different content class mirrored to each cloud, e.g.
# family-archive photos to one cloud and videos to another. There are no snapshots
# to list, so coverage is the ratio of remote bytes to the bytes the sync's own
# filter selects locally - the same measurement dropbox_cell makes, but scoped to
# a class instead of a whole share.
#
# Destinations are read from the sync script's status file rather than duplicated
# here, so family-mirror.sh stays the single source of truth for where each class
# goes.
FM_INI=/var/local/emhttp/family-mirror.ini
MIRROR_CLASSES="${BW_MIRROR_CLASSES:-}"

fm_get() {
  grep -oE "^fm_$1=\"[^\"]*\"" "$FM_INI" 2>/dev/null | head -1 | cut -d'"' -f2
}

# Lock-based liveness test. Deliberately not pgrep: the pattern would also match
# the shell that invoked this script when it happens to carry the same string on
# its command line, which has produced false positives here before.
class_running() {
  if ( exec 8>"/var/run/family-mirror-$1.lock"; flock -n 8 ); then return 1; fi
  return 0
}

# shellcheck disable=SC2086  # $2 holds zero or more flags, split on purpose
class_bytes() {
  timeout 900 "$R/bin/rclone" --config "$R/config/rclone.conf" size "$1" \
    $2 --json 2>/dev/null | grep -oE '"bytes":[0-9]+' | head -1 | cut -d: -f2
}

# As class_bytes, but tells a throttled read apart from an empty destination.
# Prints the byte count on success, the literal TRANSIENT when every attempt was
# refused by the cloud, and nothing at all when the answer was a clean empty.
# shellcheck disable=SC2086  # $extra holds zero or more flags, split on purpose
class_bytes_retry() {
  local target="$1" extra="${2:-}" tries=0 raw bytes rc
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    raw=$(timeout 900 "$R/bin/rclone" --config "$R/config/rclone.conf" size "$target" \
          $extra --json 2>&1)
    rc=$?
    bytes=$(printf '%s' "$raw" | grep -oE '"bytes":[0-9]+' | head -1 | cut -d: -f2)
    # The exit code is the authority, not the error text. rclone exits non-zero
    # if ANY directory failed to list, and under throttling it still prints a
    # JSON total for the part it managed to walk. Trusting that partial figure
    # renders as the seed going backwards, which is worse than admitting we do
    # not know. A timeout (124) prints no JSON at all and carries no matchable
    # error string, which is exactly how the first version of this let two legs
    # through. So: only a clean exit with a parsed total counts as an answer.
    # rc 0 with bytes "0" is a real empty destination and is reported as such.
    if [ "$rc" -eq 0 ] && [ -n "${bytes:-}" ]; then printf '%s' "$bytes"; return 0; fi
    [ "$tries" -lt 3 ] && sleep $(( tries * 20 ))
  done
  printf 'TRANSIENT'
  return 1
}

class_cell() {
  local share="$1" cls="$2" ck="${3:-}" dest loc rem pct when prev
  dest=$(fm_get "${cls}_dest")
  [ -n "$dest" ] || { printf -- '-'; return; }
  loc=$(class_bytes "/mnt/user/$share" "--filter-from $R/filters/$cls.txt --ignore-case")
  rem=$(class_bytes_retry "$dest" "--fast-list")
  [ -n "${loc:-}" ] && [ "$loc" -gt 0 ] 2>/dev/null || { printf -- '-'; return; }
  if [ "${rem:-}" = TRANSIENT ]; then
    # The cloud would not answer. Keep last run's figure rather than claiming the
    # seed has fallen back to zero.
    prev=$(prev_seg "$share" "$ck")
    printf '%s' "${prev:--}"
    return
  fi
  if [ -z "${rem:-}" ] || [ "$rem" -eq 0 ] 2>/dev/null; then
    if class_running "$cls"; then printf 'seed0.0'; else printf -- '-'; fi
    return
  fi
  pct=$(( rem * 1000 / loc ))
  if [ "$pct" -ge 999 ]; then
    when=$(fm_get "${cls}_done")
    printf '%s' "${when:-$(date '+%d/%m %H:%M')}"
  else
    printf 'seed%d.%d' $(( pct / 10 )) $(( pct % 10 ))
  fi
}

# Dropbox coverage for one share, expressed the way the renderer expects:
#   "DD/MM HH:MM"  fully mirrored
#   "seedNN.N"     partially uploaded, in progress - amber, not a gap
#   "-"            nothing there
dropbox_cell() {
  local s="$1" loc rem pct
  loc=$(rc_bytes "/mnt/user/$s")
  rem=$(rc_bytes "dropbox:$s" "--fast-list")
  [ -n "${loc:-}" ] && [ "$loc" -gt 0 ] 2>/dev/null || { printf -- '-'; return; }

  # Nothing uploaded yet. If a sync is in flight this share is queued behind
  # another one, not missing - the script works through SHARES in order. Report
  # it as 0% uploading rather than a red gap, which would say "no copy exists and
  # nothing is being done about it" while a transfer is actively working towards
  # it. A genuine gap is when nothing is there AND nothing is running.
  if [ -z "${rem:-}" ] || [ "$rem" -eq 0 ] 2>/dev/null; then
    if pgrep -f "[r]clone-dropbox-sync" >/dev/null 2>&1; then
      printf 'seed0.0'
    else
      printf -- '-'
    fi
    return
  fi

  # integer tenths of a percent, to avoid depending on bc
  pct=$(( rem * 1000 / loc ))
  if [ "$pct" -ge 999 ]; then
    # Complete. Timestamp the last successful sync if the script recorded one,
    # otherwise now - the bytes are what is being asserted, not the clock.
    local when
    when=$(grep -oE 'rc_updated="[^"]+"' /var/local/emhttp/rclone-dropbox.ini 2>/dev/null \
           | head -1 | cut -d'"' -f2)
    printf '%s' "${when:-$(date '+%d/%m %H:%M')}"
  else
    printf 'seed%d.%d' $(( pct / 10 )) $(( pct % 10 ))
  fi
}

: > "$TMP"
for entry in $SETS; do
  repo="${entry%%:*}"
  stores="${entry#*:}"
  cd "$(repo_root "$repo")" 2>/dev/null || continue
  out=""
  for st in ${stores//,/ }; do
    # Retry a throttled storage rather than recording it as a gap. A clean empty
    # listing breaks out immediately - that is a real answer, not a refusal.
    line=""; throttled=""; tries=0
    while [ "$tries" -lt 3 ]; do
      tries=$((tries + 1))
      # 300s, not 90: duplicacy downloads every revision file to print its date,
      # and 324 paperless revisions on Dropbox took 140s on 2026-11-07.
      raw=$(timeout 300 "$D/bin/duplicacy" list -storage "$st" 2>&1)
      rc=$?
      # Revisions print oldest first, so only a listing that ran to the end
      # (rc 0) says which one is newest. A timeout kills duplicacy mid-listing
      # with rc 124, and its last line is just wherever it got to - that once
      # showed paperless on Dropbox at r576 from August while r823 was an hour
      # old. Partial output is a refusal, never an answer.
      line=""
      [ "$rc" -eq 0 ] && line=$(printf '%s' "$raw" | grep "^Snapshot tower-$repo revision" | tail -1)
      [ -n "$line" ] && { throttled=""; break; }
      # Only a clean exit that simply listed no snapshots is a real "nothing is
      # here". Anything else is treated as a refusal, not a gap.
      if [ "$rc" -eq 0 ] && ! transient_err "$raw"; then break; fi
      throttled=1
      [ "$tries" -lt 3 ] && sleep $(( tries * 20 ))
    done
    if [ -n "$line" ]; then
      dt=$(echo "$line" | sed -nE 's/.*created at ([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}:[0-9]{2}).*/\3\/\2 \4/p')
      rev=$(echo "$line" | sed -nE 's/.*revision ([0-9]+) .*/\1/p')
      [ -z "$dt" ] && dt="?"
      out="$out${st:0:1}:r${rev}@${dt}|"
    elif p=$(seed_pct "$repo" "$st"); then
      out="$out${st:0:1}:seed${p%\%}|"
    elif [ -n "$throttled" ] && prev=$(prev_seg "$repo" "${st:0:1}") && [ -n "$prev" ]; then
      # Storage refused to list and we have a previous reading. Stale but true
      # beats a fabricated gap on a repo that is still being backed up.
      out="$out${st:0:1}:${prev}|"
    else
      out="$out${st:0:1}:-|"
    fi
  done

  # Dropbox, measured by rclone rather than asked of Duplicacy
  case " $MIRRORED " in
    *" $repo "*) out="${out}d:$(dropbox_cell "$repo")|" ;;
  esac

  # Class mirrors: "dataset:cloudkey=class,cloudkey=class"
  for mspec in $MIRROR_CLASSES; do
    [ "${mspec%%:*}" = "$repo" ] || continue
    for kv in $(echo "${mspec#*:}" | tr ',' ' '); do
      ck="${kv%%=*}"; cls="${kv#*=}"
      out="$out$ck:$(class_cell "$repo" "$cls" "$ck")|"
    done
  done

  key=$(echo "$repo" | tr -- '-' '_')
  echo "cov_${key}=\"${out%|}\"" >> "$TMP"
done
echo "cov_updated=\"$(date '+%d/%m %H:%M')\"" >> "$TMP"
mv "$TMP" "$OUT"
TMP=""

# Local file counts for the mirrored shares, cached for the per-minute live
# script. That script needs a denominator to turn "files copied" into a
# percentage, but walking 21k files every minute is wasteful and asking Dropbox
# would burn API calls, so the number is refreshed here on the 6h cycle instead.
TOT=/var/local/emhttp/rclone-dropbox-totals.ini
TOT_TMP="${TOT}.$$"
{
  for s in $MIRRORED; do
    n=$(timeout 300 "$R/bin/rclone" --config "$R/config/rclone.conf" size "/mnt/user/$s" \
        "${EX[@]}" --json 2>/dev/null | grep -oE '"count":[0-9]+' | head -1 | cut -d: -f2)
    [ -n "${n:-}" ] && echo "rt_$(echo "$s" | tr -- '-' '_')=\"$n\""
  done
  echo "rt_updated=\"$(date '+%d/%m %H:%M')\""
} > "$TOT_TMP"
mv "$TOT_TMP" "$TOT"
TOT_TMP=""
