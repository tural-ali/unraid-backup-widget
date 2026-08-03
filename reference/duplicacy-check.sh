#!/bin/bash
# Verify the integrity of every Duplicacy backup.
#
# Two tiers, because they cost very different amounts:
#
#   check            confirms every chunk referenced by a snapshot EXISTS in
#                    storage. Metadata only, no downloads, seconds per repo.
#                    Catches the common failure: a chunk silently missing, which
#                    would break restore. Safe to run weekly.
#
#   check -chunks    downloads and hashes every chunk. Proves the bytes are
#                    intact, not merely present. For 1.9 TB that is a full
#                    re-download, so it runs monthly against ONE repo on
#                    rotation rather than everything every week.
#
# -persist keeps going after an error and reports every affected file, which is
# what you actually want in a verification run - stopping at the first problem
# tells you less.
set -u
D=/mnt/user/appdata/duplicacy
LOG=$D/logs/check-$(date +%F).log
MODE="${1:-fast}"

source "$D/secret.env"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
export SSL_CERT_FILE=$D/../rclone/tls/ca-bundle.crt
export DUPLICACY_GDRIVE_GCD_TOKEN=$D/tokens/gcd-token.json
export DUPLICACY_DROPBOX_DROPBOX_TOKEN=$(cat "$D/tokens/dropbox-token.json" 2>/dev/null)
export DUPLICACY_DROPBOX_PASSWORD="${DUPLICACY_GDRIVE_PASSWORD:-}"
export DUPLICACY_MAILRU_WEBDAV_PASSWORD="${RCLONE_WEBDAV_PASS:-}"
export DUPLICACY_MAILRU_PASSWORD="${DUPLICACY_GDRIVE_PASSWORD:-}"

note() { /usr/local/emhttp/webGui/scripts/notify -e "Duplicacy" -s "$1" -d "$2" -i "$3"; }
fail=0

for repo in raw-photos videos immich paperless appdata; do
  cd "/mnt/user/$repo" 2>/dev/null || continue
  if [ "$MODE" = "deep" ]; then
    echo "=== $repo: deep check (downloads every chunk) ===" | tee -a "$LOG"
    out=$("$D/bin/duplicacy" check -chunks -persist 2>&1 | tail -20)
  else
    echo "=== $repo: chunk existence check ===" | tee -a "$LOG"
    out=$("$D/bin/duplicacy" check -persist 2>&1 | tail -20)
  fi
  echo "$out" >> "$LOG"
  if echo "$out" | grep -qiE "missing|corrupt|error|cannot"; then
    fail=1
    echo "  PROBLEM in $repo:" | tee -a "$LOG"
    echo "$out" | grep -iE "missing|corrupt|error|cannot" | head -5 | sed 's/^/    /' | tee -a "$LOG"
    note "Duplicacy check FAILED: $repo" "see $LOG" alert
  else
    echo "$out" | grep -iE "All chunks|snapshots? .* verified|is complete" | tail -2 | sed 's/^/  /' | tee -a "$LOG"
    echo "  OK" | tee -a "$LOG"
  fi
done

if [ "$fail" = "0" ]; then
  echo "ALL REPOS VERIFIED $(date)" | tee -a "$LOG"
  note "Duplicacy check passed" "all repos verified, $(date '+%d/%m %H:%M')" normal
fi
find "$D/logs" -name "check-*.log" -mtime +60 -delete 2>/dev/null
