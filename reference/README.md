# reference/

**Not part of the plugin.**
These are the Duplicacy and rclone jobs the widget reports on, copied from the author's server so the reporting logic can be read alongside the thing it reports on.
Last synced 2026-11-09.

| File | Schedule | What it is |
|---|---|---|
| `backup.sh` | 02:30 daily | nightly Duplicacy run: Google Drive primary, Dropbox second copy, on-array paperless copy, Sunday prune |
| `immich-backup.sh` | 04:00 daily | Immich database dump and settings to Google Drive and Dropbox |
| `paperless-hourly.sh` | hourly at :15 | paperless to both clouds, with its own healthchecks.io dead-man's switch |
| `db-snapshots.sh` | called by `backup.sh` | consistent copies of live SQLite databases, taken by `backup.sh` before the appdata leg |
| `duplicacy-check.sh` | Sat 06:00 fast, 8th 07:00 deep | integrity verification, fast and deep tiers |
| `watchdog.sh` | 09:00 daily | alerts when no success marker is recent, or a heavy job runs too long |
| `family-clone.sh` | 03:10 daily | rclone clone of family-archive to Google Drive; deletions propagate only from a cull bin |
| `hc-ping.sh` | called by the jobs above | reports job outcomes to healthchecks.io by check UUID |

`backup.sh`, `immich-backup.sh` and `duplicacy-check.sh` share `/var/run/duplicacy-heavy.lock` and wait for it rather than skip.
A check that runs while a prune is in progress reports the revisions being pruned as missing chunks, which is a false alarm.

None of them contains a credential.
Every secret is read from a file or the environment at runtime, and the one healthchecks.io ping URL is replaced with `<check-uuid>`.
Do not run these as-is: paths, share names and storage names are specific to one host.
