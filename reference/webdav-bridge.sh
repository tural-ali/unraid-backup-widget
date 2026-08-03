#!/bin/bash
# Serves the mail.ru remote as a local WebDAV endpoint so Duplicacy can treat it
# as a first-class storage (mail.ru retired native WebDAV; rclone speaks their
# native API). Loopback only - never exposed off the host.
# Idempotent: exits quietly if already running. Called at boot and by cron.
# Credentials come from the htpasswd file, not from argv: a --pass flag here
# would be readable by any `ps` on the host.
if pgrep -f "[s]erve webdav mailru:" >/dev/null; then
  exit 0
fi

# Wait for DNS before starting. /boot/config/go runs this during boot, before
# the resolver is up, and rclone needs to reach o2.mail.ru to authorise at
# startup - it exits fatally if it cannot ("failed to authorize ... lookup
# o2.mail.ru ... connection refused"). That happened on the 2026-07-28 reboot
# and left the mail.ru storage with no bridge until the next cron tick.
for attempt in $(seq 1 60); do
  if getent hosts o2.mail.ru >/dev/null 2>&1; then
    break
  fi
  # Re-check on every iteration, not just before the loop: a boot-time
  # instance can sit here for minutes while cron or a manual run starts the
  # bridge, and without this it would exec a SECOND rclone on the same port.
  if pgrep -f "[s]erve webdav mailru:" >/dev/null; then
    exit 0
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') CRITICAL: DNS never resolved o2.mail.ru after 300s, not starting" \
      >> /var/log/rclone-webdav.log
    exit 1
  fi
  sleep 5
done

if pgrep -f "[s]erve webdav mailru:" >/dev/null; then
  exit 0
fi

exec /mnt/user/appdata/rclone/bin/rclone \
  --config /mnt/user/appdata/rclone/config/rclone.conf \
  serve webdav mailru: \
  --addr 127.0.0.1:8090 \
  --htpasswd /mnt/user/appdata/rclone/config/webdav.htpasswd \
  --cert /mnt/user/appdata/rclone/tls/cert.pem \
  --key /mnt/user/appdata/rclone/tls/key.pem \
  --log-file /var/log/rclone-webdav.log \
  --log-level NOTICE
