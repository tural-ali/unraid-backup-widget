# Decisions

Why the plugin is built the way it is, including things that were tried and abandoned. The
rejected options are the useful part - each one was a real dead end, and without a record
they get retried.

## Live data

**Cron cannot produce per-second figures.** The first version drove everything from cron
files. The fastest useful tier was one minute, and byte-accurate progress needed a Dropbox
listing call which cannot run every second without burning API quota. During a 1.5 TB seed a
number that moves once a minute reads as frozen.

**rclone's `--stats` output was the obvious fallback, and it does not work here.** With
`--log-file`, this build (v1.74.4) wrote no stats lines at all - verified, zero matches
across 10,000 log lines during an active transfer. So progress had to come from somewhere
else entirely.

**Chosen: rclone's rc server.** `--rc --rc-addr 127.0.0.1:5572` exposes `core/stats`, which
answers in-process with bytes, rate, ETA and a per-file in-flight list, as often as asked.
This is what makes the tile move like the CPU graph.

Cost of that choice: enabling rc required restarting the running sync, which cost a re-scan
of already-uploaded files (no re-transfer - rclone skips matches). Also, rc can drive
rclone's remotes, including deleting cloud data, so it is loopback-bound and
password-protected.

**Rejected: file-count progress as the primary metric.** It works as a fallback and is still
used when rc is unreachable, but "9,904 of 21,546 files" is not the same shape as bytes -
one 8 GB video counts the same as one 40 KB sidecar, so the percentage lies about time
remaining.

## Wording

**"Missing backups", not "gaps".** Gap is internal jargon. The reader wants to know a backup
is absent, and "2 missing backups" says that without needing the vocabulary.

**Count datasets, not copies.** "6 of 10 cloud copies present" requires knowing the plan to
interpret - 10 of what? "3 of 5 datasets fully protected" is a fact about things the user
recognises. People think in folders, not in copies.

**"Not a target", not "Missing", for a cloud a dataset never goes to.** The original mockup
labelled these Missing, which produced four permanent warnings for copies that were never
supposed to exist. A dashboard that cries wolf about its own configuration teaches you to
ignore it.

## Colour and iconography

**Amber for a missing backup, not red.** Nothing has failed: the target is configured and
has not received data yet. Reserving red for actual errors keeps red meaningful.

**Filled dots, not glyphs.** An exclamation mark was tried for the amber state and read as
"something is wrong" rather than "not backed up yet". A filled amber dot in a column of
green dots reads as a state in a series, which is what it is.

**A ring gauge for health.** A percentage has to be parsed; a ring is read. Health is the
one number worth seeing without reading, so it gets the gauge and everything else gets text.

**Brand icons need text labels.** Icons alone above the status columns were read as belonging
to the transfer bar above them rather than heading the columns. Tiny grey provider names
fixed it.

## Layout

**Every column is a fixed pixel width.** With `fr` units the columns were content-sized, so a
cell changing from "8h ago" to "just now" resized its column and shifted every row - visible
jitter on a panel that repaints every 30 seconds. Leftover width pools in an empty trailing
column so the panel still spans the page.

**The percentage sits inside the filled bar.** Floating centred over the track it had no
relationship to the progress; at the leading edge of the fill it reads immediately. Below
14% the fill is too narrow for legible text, so it moves outside into the track.

## Deliberate omissions

**No "run backup now" button.** Requested during review, and left out. An authenticated web
endpoint that executes backup jobs as root is a materially different security surface from
one that reads status files, and the convenience is small - these jobs are on cron and the
whole point of the panel is to tell you whether they worked. Adding it later means thinking
about CSRF, concurrency against a running job, and what happens when someone clicks twice.

**No "Open WebUI" link.** The mockup had one. There is no Duplicacy web GUI on this host -
the paid one was declined - so the button would have 404'd. It is a working "Refresh now"
instead.

**No log viewer.** The detail panel shows the dataset path and per-cloud state. Streaming
root-readable logs through the web UI is another surface, and the logs are one `ssh` away.

## Packaging

**Base64-embedded payload in the `.plg`, not a `.txz` download.** Two reasons. The repository
is private and Unraid's installer fetches anonymously, so a raw URL would 404. And the
payload is PHP and JavaScript full of `<`, `>` and `&`; a `.plg` is XML parsed by Unraid
itself, so embedding source verbatim is fragile the first time someone writes `]]>`. Base64
is inert.

**Shell blocks inside the manifest are CDATA-wrapped.** They contain redirections and `||`,
which are markup outside CDATA. The base64 blocks need no wrapping.

**Config kept on removal.** The uninstall block deletes the RAM copy and the cron file but
leaves `/boot/config/plugins/backup-widget/`, so reinstalling does not lose the operator's
config.

## Mistakes worth not repeating

**The tile registration shape.** Unraid wants
`$mytiles[$plugin]['columnN'] = "<tbody>…</tbody>"`. An array of name/title/body registers
nothing, logs nothing, and the tile just does not appear. Verifying that the *renderer*
produces good HTML proves nothing about whether Unraid will consume it - test the
registration.

**tmpfs versus flash.** Editing `/boot/config/plugins/<name>/` alone changes nothing until
the next boot; editing `/usr/local/emhttp/plugins/<name>/` alone is lost at the next boot.
Both need writing, and the `.plg` file list must name every file.

**Verification that only matches one error format.** A capability probe recognised Dropbox's
verbose scope error but not the terser `missing_scope`, and reported success against a
failure. A probe should exercise the operation and treat anything but a clean result as
failure, not pattern-match known error strings.

## Scoring (revised 2026.08.04)

**First attempt: percentage of datasets where every target holds a copy.** It read 40% for an
estate that was in decent shape - two datasets perfect, two missing only their optional third
copy, one mid-upload. 40% says "almost everything is broken". A metric that overstates danger
gets ignored exactly like one that understates it, so it was replaced.

**Now: per-dataset coverage, averaged, with half credit for uploads in progress.** A dataset
with three targets is no longer punished three times for one absence, and a copy actively
being produced counts for something. The same estate scores 75%, which matches how it
actually feels. The word breakdown next to the gauge - `2 full · 2 syncing · 1 partial` -
carries the detail a single number cannot.

**Rejected: weighting clouds by importance.** Tempting - the first copy matters more than the
third - but any weighting is a judgement encoded as arithmetic, and it would need explaining
every time someone asked why a number moved. Equal weight per target inside a dataset is at
least predictable.

## History sparkline

A snapshot cannot answer "is this dataset reliably healthy, or does it fail every other
run?" - and that is often the more useful question. Each 6-hourly coverage check now appends
one sample per dataset to `history.tsv` on flash, and the tile draws the last 14 as bars.

**On flash, not in RAM.** History that resets at every reboot is not history. Four writes a
day of a few hundred bytes is nothing against flash wear, and the file is trimmed to 40
samples per dataset.

**Bar height encodes state as well as colour**, so the row is still readable in monochrome
or to a colour-blind reader: full height for healthy, two thirds for syncing, under half for
degraded.

The sparkline shows `···` until samples exist. At a 6-hourly cadence a full 14-bar history
takes about three and a half days to build, which is honest rather than backfilled with
invented data.

## Wording, second pass

- **"Attention required" above the count.** Naming the state before the number reads faster
  than a bare "2 missing backups".
- **"backup targets missing"**, not "missing backups" - it is a target that lacks a copy, and
  saying so avoids implying a backup was lost.
- **A dash, not a hollow ring, for a cloud that is not a target.** An empty circle reads as
  "inactive" or "off"; a dash reads as not-applicable, which is what it means.

## Polish pass (2026.08.05)

**Dropped the "Attention required" headline.** Above a count that already names the problem it
was pure redundancy, and the tile has no spare vertical room. The score label plus the count
carries it.

**Syncing is green in the breakdown, blue in the sparkline, and that inconsistency is
deliberate.** The breakdown answers "is this healthy?" - a copy being actively produced is
healthy, and blue reads as merely informational. The sparkline answers "what was the state at
that sample?" - and mid-transfer is genuinely a different state from complete, which is the
distinction the sparkline exists to draw.

**One family of dots, GitHub-Actions style.** Filled green / blue sync arrows / filled amber /
pale grey. A row of dots in different colours is read faster than a row of mixed glyphs. The
not-configured state took three attempts: an exclamation mark read as "broken", a hollow ring
read as "inactive", and a dash read as missing data. A greyed member of the same dot family
reads as a state in the series, which is what it is.

**Amber softened from `#d97706` to `#b45309`.** The brighter tone dominated a tile where it is
only meant to draw the eye.

**Rich native tooltips instead of more UI.** Each dot's `title` carries cloud, tool, last
backup with revision, and source path across several lines. Hovering answers the question the
expandable row was added for, without occupying any space.

## Mistakes worth not repeating (continued)

**A one-line comment swallowed the next statement.** A scripted edit appended `// softened...`
to a line that continued `$blue = '#2563eb';`, putting the assignment inside the comment. The
page still rendered - PHP treats the undefined variable as empty - so every blue element
silently lost its colour with no error anywhere. Rendering successfully is not evidence of
correctness; the check that caught it was grepping the OUTPUT for the expected colour.

## Polish pass 2 (2026.08.06)

**Expanded rows collapsing after a few seconds was a bug, not a preference.** The 30s tick
replaces every node in the tile, and which rows were open lived only in the nodes being thrown
away. Open state now lives in `window.bwOpen`, is written to `localStorage` so it survives a
dashboard reload, and is re-applied after every rebuild.

**Five wide bars, not fourteen hairlines.** At 3px the history row read as a single tick and
was unintelligible without having been told what it was. At 6px across five samples it reads
as a sequence. The expansion also carries a labelled `History` row, because the collapsed
version is necessarily terse.

**"Protection score", not "Backup score".** It scores how well the data is protected across
targets, not whether jobs ran - the more precise word is worth using.

**A shield, not a heartbeat.** The heart implied general system-health monitoring; this widget
is specifically about backup integrity.

**One action, and it goes to the overview.** There is no Duplicacy web UI on this host to link
to, and an endpoint that runs backups from a web page is a security surface this deliberately
does not have. So `details →` opens Tools → Backup Overview, which has the per-cloud detail
and the attention list.

## Mistakes worth not repeating (continued)

**JavaScript comparison operators broke XML well-formedness.** The tile fragment must parse as
XML, and a patch that added `if (p >= 14)` / `if (p < 14)` to the live tick put literal angle
brackets inside `<script>`. The tile still rendered - browsers parse HTML leniently - so
nothing looked wrong, and an earlier check that only counted `&&` passed it. The endpoint now
sends a boolean `inside` flag and the script contains no comparisons at all.

The lesson generalises: the check must test the actual invariant. Counting `&&` tested one
instance of the rule rather than the rule, which is "the fragment parses as XML". That is now
what gets asserted, by parsing it.
