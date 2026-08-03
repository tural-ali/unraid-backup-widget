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
