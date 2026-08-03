# reference/

**Not part of the plugin.** These are the Duplicacy and rclone jobs the widget was written
against, kept here so the reporting logic can be read alongside the thing it reports on.

| File | What it is |
|---|---|
| `backup.sh` | nightly Duplicacy run: Google Drive primary, mail.ru third copy |
| `rclone-dropbox-sync.sh` | the Dropbox mirror, and where `--rc` is enabled |
| `duplicacy-check.sh` | integrity verification, fast and deep tiers |
| `webdav-bridge.sh` | rclone serving mail.ru as local WebDAV for Duplicacy |

None of them contains a credential; every secret is read from a file or the environment at
runtime. Do not run these as-is - paths, share names and storage names are specific to one
host.
