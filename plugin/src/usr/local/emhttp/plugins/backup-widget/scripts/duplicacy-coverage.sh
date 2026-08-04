#!/bin/bash
# Builds the per-repo / per-storage coverage picture for the dashboard tile.
# Each check hits the cloud and takes seconds, so this runs every 6h (and after
# the nightly run) rather than every minute like the progress script.
# Output: /var/local/emhttp/duplicacy-coverage.ini
#
# Two different tools own two different clouds, and the tile has to reflect that:
#
#   Google Drive, mail.ru   Duplicacy. Coverage = newest committed snapshot,
#                           found with `duplicacy list`.
#   Dropbox                 rclone sync. There are no snapshots to list - it is a
#                           plain file mirror - so coverage is measured by
#                           comparing bytes present remotely against bytes
#                           locally, using the SAME filters the sync uses.
#
# Asking Duplicacy about Dropbox, as this script used to, now reports "no copy"
# forever: the repo there was purged on 2026-08-03 and Dropbox belongs to the
# mirror. That read as a permanent red gap for every share.
set -u
# Configuration, shared with the settings page and the renderers. KEY="value" so
# this file is both parse_ini_file-able and source-able - one file, no second
# parser to drift. Absent config falls back to the defaults below.
CONF=/boot/config/plugins/backup-widget/config
[ -f "$CONF" ] && . "$CONF"
: "${DUP_DIR:=/mnt/user/appdata/duplicacy}"
: "${RCLONE_DIR:=/mnt/user/appdata/rclone}"

D=$DUP_DIR
R=$RCLONE_DIR
OUT=/var/local/emhttp/duplicacy-coverage.ini
TMP="$OUT.tmp"

source $D/secret.env
export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
export SSL_CERT_FILE=$R/tls/ca-bundle.crt
export DUPLICACY_GDRIVE_GCD_TOKEN=$D/tokens/gcd-token.json
export DUPLICACY_MAILRU_WEBDAV_PASSWORD="${RCLONE_WEBDAV_PASS:-}"
export DUPLICACY_MAILRU_PASSWORD="${DUPLICACY_GDRIVE_PASSWORD:-}"

# repo:duplicacy-storages. Dropbox is deliberately absent - it is rclone's now.
# raw-photos and appdata gained mailru on 2026-08-03.
SETS="${BW_SETS:-raw-photos:gdrive,mailru videos:gdrive paperless:gdrive,mailru appdata:gdrive,mailru immich:gdrive}"

# Shares the rclone mirror covers. Must match SHARES in rclone-dropbox-sync.sh.
MIRRORED="${BW_MIRRORED:-videos raw-photos}"

# Same exclusions the sync applies, so a filtered-out file cannot make a
# complete mirror look short of 100%.
EX=(--exclude '.DS_Store' --exclude '._*' --exclude '.duplicacy/**' --exclude '**/@eaDir/**')

# Duplicacy writes a snapshot only when a backup finishes, so a first seed is
# invisible to `duplicacy list` - it looks identical to "nothing has ever run".
# Detect the live process by its working directory and report the percentage.
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
    pct=$(grep -oE '[0-9]+\.[0-9]%$' "$log" 2>/dev/null | tail -1)
    printf '%s' "${pct:-0.0%}"
    return 0
  done
  return 1
}

# bytes of a path as rclone sees it, honouring the sync's filters
rc_bytes() {
  local target="$1" extra="${2:-}"
  timeout 300 "$R/bin/rclone" --config "$R/config/rclone.conf" size "$target" \
    "${EX[@]}" $extra --json 2>/dev/null \
    | grep -oE '"bytes":[0-9]+' | head -1 | cut -d: -f2
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
  cd "/mnt/user/$repo" 2>/dev/null || continue
  out=""
  for st in ${stores//,/ }; do
    line=$(timeout 90 "$D/bin/duplicacy" list -storage "$st" 2>/dev/null \
           | grep "^Snapshot tower-$repo revision" | tail -1)
    if [ -n "$line" ]; then
      dt=$(echo "$line" | sed -nE 's/.*created at ([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}:[0-9]{2}).*/\3\/\2 \4/p')
      rev=$(echo "$line" | sed -nE 's/.*revision ([0-9]+) .*/\1/p')
      [ -z "$dt" ] && dt="?"
      out="$out${st:0:1}:r${rev}@${dt}|"
    elif p=$(seed_pct "$repo" "$st"); then
      out="$out${st:0:1}:seed${p%\%}|"
    else
      out="$out${st:0:1}:-|"
    fi
  done

  # Dropbox, measured by rclone rather than asked of Duplicacy
  case " $MIRRORED " in
    *" $repo "*) out="$out"d:"$(dropbox_cell "$repo")|" ;;
  esac

  key=$(echo "$repo" | tr -- '-' '_')
  echo "cov_${key}=\"${out%|}\"" >> "$TMP"
done
echo "cov_updated=\"$(date '+%d/%m %H:%M')\"" >> "$TMP"
mv "$TMP" "$OUT"

# Local file counts for the mirrored shares, cached for the per-minute live
# script. That script needs a denominator to turn "files copied" into a
# percentage, but walking 21k files every minute is wasteful and asking Dropbox
# would burn API calls, so the number is refreshed here on the 6h cycle instead.
TOT=/var/local/emhttp/rclone-dropbox-totals.ini
{
  for s in $MIRRORED; do
    n=$(timeout 300 "$R/bin/rclone" --config "$R/config/rclone.conf" size "/mnt/user/$s" \
        "${EX[@]}" --json 2>/dev/null | grep -oE '"count":[0-9]+' | head -1 | cut -d: -f2)
    [ -n "${n:-}" ] && echo "rt_$(echo "$s" | tr -- '-' '_')=\"$n\""
  done
  echo "rt_updated=\"$(date '+%d/%m %H:%M')\""
} > "$TOT.tmp"
mv "$TOT.tmp" "$TOT"
