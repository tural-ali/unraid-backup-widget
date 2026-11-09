#!/bin/bash
# healthchecks.io heartbeat for scheduled jobs and state checks.
#
# Usage: hc-ping.sh <slug> [up|down] [message]
#
# Every alert on this box fires on failure, so silence reads as success: a vanished
# cron entry or a dead docker sends nothing. A healthchecks.io check expects a ping
# on its cron schedule and alerts (Telegram group "Tower Notifications") when it
# does not arrive, and it does so from outside, so it still fires when the whole
# Tower is down. Silence becomes the alarm.
#
# <slug> is looked up in /boot/config/healthchecks/checks.conf ("slug=uuid", root
# only) and pinged by the check's UUID. A slug with no line there is a silent
# no-op, so instrumenting a script can never break the script itself, and a typo
# cannot create a new, unwatched check. "down" pings /fail. The message is the
# ping body and shows up in the alert.
#
# Why UUIDs and not the project ping key with /<key>/<slug> URLs: from 2026-10-06
# to 2026-11-08 the ping-key file held a mangled value (a key plus a slug, pasted
# from a URL), healthchecks.io answered every ping with 400 or 404, and because
# this script swallowed the response nothing noticed for a month - every check
# sat at "never pinged", which never alerts. UUIDs are shown in full on the
# checks page, so a wrong one is easy to spot. A refused ping is now logged to
# syslog (tag hc-ping) rather than dropped.
SLUG="$1"; STATUS="${2:-up}"; MSG="${3:-OK}"

# Migration from Uptime Kuma push monitors (2026-10-06): while uk-tokens.conf
# still exists, the same heartbeat also goes to Kuma. Deleting uk-tokens.conf
# (with the Kuma push monitors) ends it; then remove this block and uk-push.sh.
D="$(dirname "$0")"
[ -r "$D/uk-tokens.conf" ] && "$D/uk-push.sh" "$SLUG" "$STATUS" "$MSG"

[ -n "$SLUG" ] || exit 0
UUID=$(awk -F= -v s="$SLUG" '$1 == s { print $2; exit }' \
       /boot/config/healthchecks/checks.conf 2>/dev/null | tr -d '[:space:]')
[ -n "$UUID" ] || exit 0
SUFFIX=""; [ "$STATUS" = "down" ] && SUFFIX="/fail"
if ! out=$(curl -sS -m 10 --retry 3 -w ' http=%{http_code}' --data-raw "$MSG" \
             "https://hc-ping.com/$UUID$SUFFIX" 2>&1) || [ "${out#OK }" = "$out" ]; then
  logger -t hc-ping "$SLUG $STATUS refused: $out"
fi
exit 0
