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

Or install by URL from **Plugins → Install Plugin**:

```
https://raw.githubusercontent.com/tural-ali/unraid-backup-widget/main/plugin/backup-widget.plg
```

That URL is also the manifest's `pluginURL`, so Unraid can check it for updates. The payload
is base64-embedded in the manifest, so installation fetches nothing further: PHP source is
full of `<`, `>` and `&`, and a `.plg` is XML that Unraid parses itself.

After installing:

- **Dashboard** → tile in column 2
- **Tools → Backup Overview** → full page
- **Settings → Utilities → Backup Widget** → configuration

## Configuration

**Settings → Utilities → Backup Widget.** Nothing needs editing by hand.

The page discovers what is already on the system rather than asking you to describe it: the
shares under `/mnt/user`, and the storage names defined in each Duplicacy repo's own
preferences. A cloud you cannot actually check is shown as `unavailable` rather than offered,
so the form cannot create a target that will never be satisfiable.

Tick a cloud only where a dataset is *supposed* to have a copy. An unticked cloud reports as
"not configured" in grey and is never counted as a missing backup - leaving something off is
recorded as a decision, not a warning.

Mark a dataset **Paused** when its cloud backup is intentionally suspended.
It remains visible with its current local size and file count, while its cloud cells and history show `paused` and it is excluded from backup-score and gap calculations.

It writes one file, `/boot/config/plugins/backup-widget/config`, in `KEY="value"` form so PHP
and bash both read it directly. Editing it by hand still works; see
`plugin/src/boot/config.example`. With no config at all the plugin runs on defaults.

The save handler executes nothing, requires a valid Unraid CSRF token, and validates every
field against the shares that actually exist - the file is later sourced by bash, so injection
is rejected rather than escaped.

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
    settings-save.php         validating POST handler for the settings form
    BackupOverview.page       Tools page
    BackupWidget.page         dashboard tile
    BackupSettings.page       Settings → Utilities page
    scripts/                  the six cron collectors
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
echo 2026.08.14 > VERSION
./tools/build-plg.sh
git commit -am "..." && git tag v2026.08.14 && git push --follow-tags
```

The tag, the manifest and the installed plugin all read the same value, so there is no way
to have a version that only exists in one of them.
