# backup-widget

An Unraid dashboard tile and full-page overview that answers three questions at a glance:

- Is a backup running, and how far along is it?
- Which datasets have every copy they are supposed to have?
- Which ones are still missing a copy, and where?

It **reports on** backups. It does not run them, schedule them, or hold their credentials.
Duplicacy and rclone stay exactly where they were, under your control; this reads their
output.

## What it looks at

Two tools own two different clouds, and the plugin keeps them distinct throughout,
because they fail differently and are restored differently.

| Cloud | Tool | Kind of copy | What "green" means |
|---|---|---|---|
| Google Drive | Duplicacy | Chunked, encrypted, versioned | A committed snapshot exists |
| Dropbox | rclone `sync` | Plain browsable files | The bytes are present remotely |
| mail.ru | Duplicacy | Chunked, encrypted, versioned | A committed snapshot exists |

A dataset that is deliberately not sent to a cloud shows a grey ring, never a warning.
Treating a decision as a failure is how people learn to ignore warnings.

## Install

```bash
cp plugin/backup-widget.plg /boot/config/plugins/
```

Then install it from **Plugins → Install Plugin** pointing at that file, or just let the
`.plg` run. It is entirely self-contained: every file is embedded, so nothing is fetched
from the network at install time. That matters because this repository is private and
Unraid's installer fetches anonymously.

After installing:

- **Dashboard** → tile in column 2
- **Tools → Backup Overview** → full page

## Configuration

Defaults match the host it was written on. If your layout differs, copy
`plugin/src/boot/config.example` to `/boot/config/plugins/backup-widget/config` and edit.
The plugin runs unchanged with the file absent.

The important keys are which datasets to report on (`BW_SHARES`), which Duplicacy storages
each one targets (`BW_SETS`), and which the rclone mirror covers (`BW_MIRRORED`). A cloud
absent from `BW_SETS` for a dataset is treated as "not a target" and never counted as a
missing backup.

## How the live numbers work

Per-second figures do **not** come from cron. The page queries rclone's remote-control
server directly, in-process, which is the only way to make a transfer read like a CPU
graph rather than a page that reloads. Everything slower is cached by cron so that opening
a browser tab never triggers a cloud call:

| Interval | What | Cost |
|---|---|---|
| on request | bytes, rate, ETA, in-flight filenames | rclone rc, local socket |
| 1 min | Duplicacy progress, mirror file counts | local log parsing |
| 5 min | byte-accurate mirror progress | one Dropbox listing call |
| 6 h | snapshot coverage, dataset sizes | all three clouds, plus `du` |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the data flow and
[docs/DECISIONS.md](docs/DECISIONS.md) for why it is built this way, including several
things that were tried and rejected.

## Repository layout

```
plugin/backup-widget.plg      generated - do not edit by hand
plugin/src/                   the actual sources
  usr/local/emhttp/plugins/backup-widget/
    overview.php              shared state + full-page renderer
    overview-widget.php       compact tile renderer
    overview-live.php         1s JSON endpoint
    overview-poll.php         30s page endpoint
    widget-poll.php           30s tile endpoint
    BackupOverview.page       Tools page
    BackupWidget.page         dashboard tile
    scripts/                  the five cron collectors
  boot/
    backup-widget.cron        collector schedule
    config.example            documented defaults
tools/build-plg.sh            regenerates the manifest from src/
reference/                    the host's own backup jobs, for context only
docs/                         architecture, decisions, operations
```

`reference/` is **not** part of the plugin. Those are the Duplicacy and rclone jobs this
was written against, included so the reporting logic can be read against the thing it
reports on.

## Versioning

Date-based, Unraid convention: `YYYY.MM.DD` in `VERSION`, which `tools/build-plg.sh` reads
into the manifest. Bump it, rebuild, commit, tag:

```bash
echo 2026.08.10 > VERSION
./tools/build-plg.sh
git commit -am "..." && git tag v2026.08.10 && git push --follow-tags
```

The tag, the manifest and the installed plugin all read the same value, so there is no way
to have a version that only exists in one of them.
