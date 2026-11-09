#!/bin/bash

# Uptime Kuma heartbeat. A trap, not a line at the end: these scripts exit early
# on normal paths (nothing to do, lock held, dependency absent) and a tail-placed
# push would never run, so the monitor would go DOWN on a healthy system.
# shellcheck disable=SC2329  # invoked by the EXIT trap
_uk_hb(){ local rc=$?; /mnt/user/appdata/scripts/hc-ping.sh duplicacy-check "$([ "$rc" -eq 0 ] && echo up || echo down)" "exit=$rc"; }
trap _uk_hb EXIT
# Verify the integrity of every Duplicacy storage.
#
#   duplicacy-check.sh fast              chunk existence, every storage
#   duplicacy-check.sh deep              download+hash, the affordable storages
#   duplicacy-check.sh deep <key> ...    download+hash, named storages only
#
# Organised by STORAGE, not by repository, and that is the whole point. Six
# repositories share gcd://Duplicacy, and a check there lists all ~537,000
# chunks in the storage before verifying anything - 15 minutes, measured, almost
# all of it the listing. Checking per repository would pay that listing six
# times over for identical coverage. One pass with -a covers every snapshot id
# in the storage instead, and no repository can be silently left out because it
# was missing from a hand-maintained list.
#
# The two tiers cost very different amounts:
#
#   check            confirms every chunk a snapshot references EXISTS. Metadata
#                    only, no downloads. Catches the failure that actually
#                    happens here - a throttled upload leaving a hole - and is
#                    cheap enough to run weekly.
#
#   check -chunks    downloads and hashes every chunk, proving the bytes are
#                    intact rather than merely present. That is a full
#                    re-download of the storage, so it is restricted to the
#                    storages where the egress is free or trivial. gcd://Duplicacy
#                    is 2.5 TB; deep-checking it monthly is not a backup policy,
#                    it is a bandwidth bill.
#
# Neither tier proves the backup is RESTORABLE. A check proves the storage is
# consistent with itself. Only a restore proves you can get the data back, which
# is what restore-drill.sh is for.
set -uo pipefail

D=/mnt/user/appdata/duplicacy
MODE="${1:-fast}"
shift 2>/dev/null || true
ONLY="$*"

# shellcheck source=/dev/null
source "$D/secret.env"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
export DUPLICACY_GDRIVE_GCD_TOKEN=$D/tokens/gcd-token.json
DUPLICACY_DROPBOX_DROPBOX_TOKEN=$(cat "$D/tokens/dropbox-token.json" 2>/dev/null)
export DUPLICACY_DROPBOX_DROPBOX_TOKEN
export DUPLICACY_DROPBOX_PASSWORD="${DUPLICACY_GDRIVE_PASSWORD:-}"
# The on-array paperless copy reuses the gdrive key rather than introducing a
# secret whose only copy would live on the machine it is protecting.
export DUPLICACY_LOCAL_PASSWORD="${DUPLICACY_GDRIVE_PASSWORD:-}"

LOG=$D/logs/check-$(date +%F).log
mkdir -p "$D/logs"
note() { /usr/local/emhttp/webGui/scripts/notify -e "Duplicacy" -s "$1" -d "$2" -i "$3"; }
say() { echo "$*" | tee -a "$LOG"; }

# key | repository root | storage name | tier | snapshot id (optional)
#
# The repository root is only an entry point - it is where duplicacy reads the
# storage URL and key from. With no snapshot id the check runs with -a and
# covers every snapshot id in that storage regardless of which repository you
# stood in. With one, it runs with -id and covers only that snapshot id, which
# is how a small set on a big shared storage gets its own deep check.
#
# tier:
#   deep      verified at both levels
#   fast      chunk existence only. A statement about egress, not about trust:
#             gdrive is 2.5 TB and dropbox://Tower 2.6 TB, both shared. Either
#             can still be deep-checked on demand - `duplicacy-check.sh deep gdrive`.
#   deeponly  deep tier only. For a per-id row whose existence check the
#             all-ids fast row on the same storage already covers.
#   off       not checked, with the reason. Reported on every run rather than
#             deleted from the table, because a storage that quietly disappears
#             from a verification list is indistinguishable from one that passes.
# The root column is only an ENTRY POINT. The check runs with -a, so it
# verifies every snapshot id on the storage regardless of which repo it
# was launched from - all it needs is a repo whose .duplicacy defines
# that storage name. gdrive was rooted at /mnt/user/family-archive until
# 2026-09-12; that repo (videos) only has dropbox now, so the row failed
# in 0s with "No storage named 'gdrive' is found" - not a data problem.
# mail.ru (paperless, appdata, immich rows) was dropped 2026-11-07 when its plan
# lapsed; those sets moved onto dropbox://Tower, the family-archive storage.
STORAGES="
gdrive|/mnt/user/appdata|gdrive|fast
dropbox|/mnt/user/family-archive|dropbox|fast
dropbox-paperless|/mnt/user/paperless|dropbox|deeponly|tower-paperless
dropbox-immich|/mnt/user/immich/backups|dropbox|deeponly|tower-immich
dropbox-icloud|/mnt/user/icloud|dropbox|off
local|/mnt/user/paperless|local|deep
"

# Why a storage is off. dropbox://Duplicacy/icloud reports "storage has not been
# initialized": the repository config survives but the storage does not, because
# the iCloud leg was switched off deliberately (watchdog.sh carries the same
# hold, "HOLD by user 2026-08-09: icloud backup off until re-enabled"). Naming it
# here keeps the gap on the report instead of turning it into a weekly false
# alarm. Re-enabling the leg means changing this back to fast or deep.
off_reason() {
  case "$1" in
    dropbox-icloud) printf 'iCloud RETIRED 2026-09-02 by user decision; no longer backed up anywhere' ;;
    *)              printf 'disabled' ;;
  esac
}

fail=0
checked=0
skipped=""
offlist=""

# Never check while a prune is running. Prune renames a doomed revision's chunks
# to fossils first and deletes the snapshot files last, so a check that lands in
# between reports every one of those revisions as missing chunks. On 2026-11-08
# the monthly deep check (07:00 on the 8th, a Sunday) met the weekly prune still
# running from 02:30 and flagged 316 paperless revisions on Dropbox - exactly the
# 316 the prune was deleting. So hold the same lock as the nightly run and the
# Immich job, and wait for it: waiting costs nothing, and a check that never ran
# fails loudly instead of looking like a pass.
exec 8>/var/run/duplicacy-heavy.lock
if ! flock -w 21600 8; then
  say "=== duplicacy check ($MODE) ABORTED $(date): duplicacy-heavy held for 6h ==="
  note "Duplicacy check ABORTED" "duplicacy-heavy held for 6h, see $LOG" alert
  exit 1
fi

say "=== duplicacy check ($MODE) started $(date) ==="

for row in $STORAGES; do
  key="${row%%|*}";  rest="${row#*|}"
  root="${rest%%|*}"; rest="${rest#*|}"
  st="${rest%%|*}";   rest="${rest#*|}"
  tier="${rest%%|*}"; sid=""
  [ "$rest" != "$tier" ] && sid="${rest#*|}"

  [ -n "$ONLY" ] && { case " $ONLY " in *" $key "*) ;; *) continue ;; esac; }

  # An explicit key on the command line overrides the tier - that is how you
  # force a deep check of gdrive, or re-test a storage that is off.
  if [ -z "$ONLY" ]; then
    if [ "$tier" = off ]; then
      offlist="$offlist
    $key: $(off_reason "$key")"
      continue
    fi
    if [ "$MODE" = deep ] && [ "$tier" = fast ]; then
      skipped="$skipped $key"
      continue
    fi
    [ "$MODE" != deep ] && [ "$tier" = deeponly ] && continue
  fi

  if ! cd "$root" 2>/dev/null; then
    fail=1; say "  $key: FAILED - repository root $root is missing"
    note "Duplicacy check FAILED: $key" "repository root $root missing" alert
    continue
  fi

  scope=(-a)
  [ -n "$sid" ] && scope=(-id "$sid")
  args=(check "${scope[@]}" -persist -storage "$st")
  [ "$MODE" = deep ] && args=(check "${scope[@]}" -persist -chunks -threads 4 -storage "$st")

  t0=$(date +%s)
  say "--- $key ($st, from $root)"
  out=$(nice -n 15 ionice -c3 "$D/bin/duplicacy" "${args[@]}" 2>&1)
  rc=$?
  t1=$(date +%s)

  # The FULL output goes to the log. The previous version kept `| tail -20` and
  # grepped that, which on a 735-revision storage discarded every line before
  # the last twenty - a missing chunk at revision 40 was thrown away unread and
  # the run reported success.
  printf '%s\n' "$out" >> "$LOG"

  # The exit code is the primary signal. The text scan is a second net over the
  # whole output, not a substitute: -persist deliberately continues past errors,
  # so a run can find real damage and still finish.
  bad=$(printf '%s' "$out" | grep -icE "chunk .* (does not exist|is missing)|missing chunks|is corrupted|failed to (decrypt|download)")
  if [ "$rc" -ne 0 ] || [ "$bad" -gt 0 ]; then
    fail=1
    say "    PROBLEM after $((t1-t0))s (rc=$rc, $bad suspect lines):"
    printf '%s' "$out" | grep -iE "chunk .* (does not exist|is missing)|missing chunks|is corrupted|failed to (decrypt|download)" \
      | head -5 | sed 's/^/      /' | tee -a "$LOG"
    note "Duplicacy check FAILED: $key" "rc=$rc - see $LOG" alert
  else
    ids=$(printf '%s' "$out" | grep -oE "snapshot [a-z-]+ at revision" | awk '{print $2}' | sort -u | tr '\n' ' ')
    revs=$(printf '%s' "$out" | grep -c "at revision .* exist")
    say "    OK in $((t1-t0))s - $revs revisions across: ${ids:-none}"
    checked=$((checked + 1))
  fi
done

[ -n "$skipped" ] && say "  not deep-checked (egress):$skipped  - run 'deep <key>' to force"
[ -n "$offlist" ] && say "  NOT CHECKED:$offlist"

if [ "$fail" = 0 ]; then
  say "=== ALL $checked STORAGES VERIFIED ($MODE) $(date) ==="
  note "Duplicacy $MODE check passed" "$checked storages verified, $(date '+%d/%m %H:%M')" normal
else
  say "=== check FINISHED WITH PROBLEMS ($MODE) $(date) ==="
fi

find "$D/logs" -name "check-*.log" -mtime +60 -delete 2>/dev/null
exit "$fail"
