# Architecture

## The shape of the problem

A backup dashboard has to answer "am I covered?" without becoming a liability itself.
Three constraints follow, and they drive most of the design:

1. **Opening a browser tab must not call a cloud.** Otherwise every dashboard view costs
   API quota, and a throttled provider makes the page hang.
2. **An unknown must never render as covered.** A blank cell is not evidence of a backup.
   Unchecked, in-progress, not-a-target and genuinely-missing are four different states and
   are drawn differently.
3. **Live progress has to be genuinely live.** A number that updates once a minute reads as
   broken during a multi-day transfer.

These pull in opposite directions - 1 wants caching, 3 wants immediacy - so the data is
split by how fast it actually changes.

## Data flow

```
                        ┌─────────────────────────────────────────┐
   rclone (running)     │ rc server on 127.0.0.1:5572             │
   ────────────────────▶│ bytes, rate, ETA, in-flight file list   │
                        └──────────────┬──────────────────────────┘
                                       │ queried per request, 1s timeout
                                       ▼
   duplicacy logs ──▶ duplicacy-status.sh   (1m)  ──▶ duplicacy.ini
   rclone log     ──▶ rclone-live.sh        (1m)  ──▶ rclone-dropbox-live.ini
   Dropbox        ──▶ rclone-progress.sh    (5m)  ──▶ rclone-progress.ini
   3 clouds       ──▶ duplicacy-coverage.sh (6h)  ──▶ duplicacy-coverage.ini
   local du       ──▶ backup-inventory.sh   (6h)  ──▶ backup-inventory.ini
   sync script    ──────────────────────────────▶ rclone-dropbox.ini
                                       │
                                       ▼
                        ┌─────────────────────────────────────────┐
                        │ overview.php :: bo_state()              │
                        │ one function, all the interpretation    │
                        └───────┬─────────────────────┬───────────┘
                                ▼                     ▼
                        bo_render()            bo_render_widget()
                        full page              dashboard tile
```

Every `.ini` lives in `/var/local/emhttp/`, which is tmpfs. That is deliberate: these are
caches, and a stale cache surviving a reboot would be worse than an empty one. The
renderers treat a missing key as *unknown*, never as *covered*.

## One interpreter, one palette, one set of marks

`bo_state()` decides what is true. `bo_pal()` and `bo_mark()` decide how it looks. All three
live in overview.php and both surfaces call them - the tile's `bw_mark()` is a delegating
wrapper kept only for name compatibility. Two surfaces with their own copies of the same five
dots is how a page and a tile end up disagreeing about what green means.

## bo_state() is the only interpreter

Both renderers call it and neither does any interpretation of its own. This is the single
most important structural decision in the plugin: a tile that says "protected" while the
page says "missing backup" would destroy trust in both, and the only way to guarantee they
agree is to give them one source of truth.

It returns, per dataset: the per-cloud cell states, how many targets exist, how many hold a
copy, size, file count, and the newest snapshot time. Plus estimate-wide figures: total
bytes, health percentage, the list of missing backups, and the current activity.

## Cell states

| State | Drawn as | Meaning |
|---|---|---|
| `ok` | filled green dot / timestamp | a copy exists, with its age |
| `syncing` | blue sync arrows / percentage | a copy is being made right now |
| `missing` | filled amber dot / "No copy yet" | configured target, nothing uploaded |
| `unknown` | dashed grey ring | not checked since boot |
| `na` | solid grey ring / "Not a target" | deliberately not sent here |

`missing` is amber, not red. Nothing is broken - the target is configured and simply has
not received data yet. Red is reserved for an actual failure, which keeps it meaningful.

## Progress: run-scoped vs share-scoped

rclone's rc reports `bytes` and `totalBytes` for the **current invocation**. After a
restart that reads 0.5% even when half the dataset is already uploaded, which looks like
the transfer went backwards.

`totalBytes` is what remains to send, so:

```
already_present = local_total - rc.totalBytes
overall_done    = already_present + rc.bytes
overall_pct     = overall_done / local_total
```

`local_total` comes from the 6-hourly inventory. The activity bar shows this share-scoped
figure; rate and ETA stay run-scoped, because "how fast is it going right now" and "when
will this finish" are both properties of the current run.

## Why Dropbox coverage is measured, not asked

Duplicacy commits a snapshot only when a backup finishes, so `duplicacy list` is a fine
coverage check for it. rclone has no snapshots - it is a plain file mirror - so coverage is
measured by comparing remote bytes against local bytes, using the **same filters the sync
applies**. Without matching filters an excluded `.DS_Store` makes a complete mirror read as
99.9% and never green.

## Refresh model

| Tick | Scope | Mechanism |
|---|---|---|
| 1s | transfer figures only | JSON, patched into the DOM via `textContent` |
| 30s | whole panel/tile | HTML, parsed as an inert document, nodes moved in |

The fast tick patches text nodes rather than rebuilding, because rebuilding at 1Hz fights
the browser for layout and dismisses any tooltip the moment it is hovered. The slow tick
uses `DOMParser` + `replaceChildren` rather than assigning markup to an HTML sink.

One consequence worth knowing: an expanded dataset row collapses on the 30s rebuild.

## Unraid integration contract

Two things about Unraid that are easy to get wrong, and both were got wrong during
development:

**Dashboard tiles.** Unraid 7.x expects
`$mytiles[$plugin]['columnN'] = "<tbody>…</tbody>"`, and the tile must *be* a `tbody`
because it is spliced into the dashboard's own table. Returning a
`['name' => …, 'title' => …, 'body' => …]` array registers nothing, produces no error, and
the tile silently does not appear.

**Fragment character set.** The emitted tile fragment is parsed as XML by the deploy check,
so the inline `<style>` and `<script>` bodies must contain no `<`, `>` or `&`. That rules
out `&&` (use nested `if`s) and CSS child selectors like `a > b` (give the element a
class).

**tmpfs vs flash.** `/usr/local/emhttp/plugins/<name>/` is RAM and is what the webserver
reads. `/boot/config/plugins/<name>/` is flash and is what survives a reboot. The `.plg`
copies flash → RAM at boot, and its file list must name every file - one added file that is
not listed vanishes on the next reboot.

## Security posture

- The plugin reads credentials from files at runtime and never stores or logs them. Nothing
  in this repository contains a secret.
- rclone's rc endpoint binds loopback only and is password-protected, with the password
  passed via environment rather than argv, because anything on argv is world-readable
  through `ps`.
- The poll endpoints live under `/plugins/`, so they sit behind Unraid's session auth and
  are not reachable unauthenticated.
- There is no "run backup now" control. A web endpoint that executes backup jobs as root is
  a materially different security surface from one that reads status files, and it was left
  out on purpose.
