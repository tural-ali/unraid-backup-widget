#!/bin/bash
# Per-provider storage headroom for the dashboard.
#
# One rclone "about" call per remote, so three API calls per run - cheap enough
# hourly, far too expensive per page render. Hence the cached ini like every other
# collector here.
#
# Free space is the number that matters, and it is not simply total minus used on
# Google Drive: Google Photos and Family sharing draw on the same quota and show up
# as "Other". rclone reports Free directly, so that is what gets stored rather than
# being recomputed and getting it wrong.
#
# A failed call carries the previous figures forward and marks them stale rather
# than discarding them. Observed in practice: Google Drive refused one hourly call
# and answered the next, and dropping the figures made the panel claim it knew
# nothing about a provider it had measured minutes earlier. A slightly old number
# with its age attached is worth more than a blank.
#
# Output: /var/local/emhttp/cloud-quota.ini
set -u
CONF=/boot/config/plugins/backup-widget/config
[ -f "$CONF" ] && . "$CONF"
: "${RCLONE_DIR:=/mnt/user/appdata/rclone}"

OUT=/var/local/emhttp/cloud-quota.ini
TMP="$OUT.tmp"
RC="$RCLONE_DIR/bin/rclone"
RCONF="$RCLONE_DIR/config/rclone.conf"

# remote:key - key matches the cloud letters the renderers already use
REMOTES="Gdrive:g dropbox:d mailru:m"

now=$(date +%s)

# Previous run's figures, for the carry-forward path. Sourced into a namespace of
# its own so a stale value can never be mistaken for a fresh one below.
prev_total=""; prev_used=""; prev_free=""; prev_other=""; prev_at=""
load_prev() {
  local k="$1"
  prev_total=""; prev_used=""; prev_free=""; prev_other=""; prev_at=""
  [ -f "$OUT" ] || return 1
  # shellcheck disable=SC1090
  eval "$(grep -E "^q_${k}_(total|used|free|other|at)=" "$OUT" | sed "s/^q_${k}_/prev_/")" 2>/dev/null
  [ -n "$prev_total" ] && [ -n "$prev_free" ]
}

: > "$TMP"
for pair in $REMOTES; do
  remote="${pair%%:*}"
  key="${pair##*:}"

  # --json gives bytes, so no parsing of "1.808 TiB" and no unit guesswork
  out=$(timeout 90 "$RC" --config "$RCONF" about "$remote:" --json 2>/dev/null)

  # rclone pretty-prints with a space after the colon, so the pattern must allow
  # whitespace. Without it every field came back empty and the collector wrote a
  # state of "ok" with no numbers at all - which the renderer would have shown as
  # zero free space.
  num() { echo "$out" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[0-9]+" | head -1 | grep -oE '[0-9]+$'; }
  total=""; used=""; free=""; other=""
  if [ -n "$out" ]; then
    total=$(num total)
    used=$(num used)
    free=$(num free)
    other=$(num other)
    # Not every provider reports every field. Absent free is derivable; absent
    # total is not, and a made-up total would produce a made-up percentage.
    [ -n "$free" ] || { [ -n "$total" ] && [ -n "$used" ] && free=$((total - used)); }
  fi

  # "ok" must mean the numbers are there. Reporting ok with empty fields is how a
  # renderer ends up drawing 0 bytes free and implying a full disk.
  if [ -n "$total" ] && [ -n "$free" ]; then
    {
      echo "q_${key}_state=\"ok\""
      echo "q_${key}_total=\"$total\""
      [ -n "$used"  ] && echo "q_${key}_used=\"$used\""
      echo "q_${key}_free=\"$free\""
      [ -n "$other" ] && echo "q_${key}_other=\"$other\""
      echo "q_${key}_at=\"$now\""
    } >> "$TMP"
    continue
  fi

  if load_prev "$key"; then
    {
      echo "q_${key}_state=\"stale\""
      echo "q_${key}_total=\"$prev_total\""
      [ -n "$prev_used"  ] && echo "q_${key}_used=\"$prev_used\""
      echo "q_${key}_free=\"$prev_free\""
      [ -n "$prev_other" ] && echo "q_${key}_other=\"$prev_other\""
      echo "q_${key}_at=\"${prev_at:-0}\""
    } >> "$TMP"
  else
    echo "q_${key}_state=\"$([ -n "$out" ] && echo no-figures || echo unreachable)\"" >> "$TMP"
  fi
done

echo "q_updated=\"$(date '+%d/%m %H:%M')\"" >> "$TMP"
mv "$TMP" "$OUT"
