# Operations

## Where things live

| Path | Persistence | Contents |
|---|---|---|
| `/boot/config/plugins/backup-widget/` | flash | source of truth, config, `scripts/` |
| `/usr/local/emhttp/plugins/backup-widget/` | **RAM** | what the webserver reads |
| `/boot/config/plugins/dynamix/backup-widget.cron` | flash | collector schedule |
| `/var/local/emhttp/*.ini` | **RAM** | the caches the renderers read |

Editing only the RAM copy is lost at the next boot. Editing only the flash copy has no
effect until the next boot. Change both, or reinstall the `.plg`.

## Development loop

Edit under `plugin/src/`, then:

```bash
./tools/build-plg.sh
```

To test on a live host without a full reinstall, copy the changed file to both locations and
lint it first - a PHP parse error in a `.page` file blanks the dashboard:

```bash
php -l overview.php
```

For a `.page` file, strip the header block before linting, since the part above `---` is not
PHP:

```bash
sed '1,/^---$/d' BackupWidget.page > /tmp/x.php && php -l /tmp/x.php
```

## Verifying the tile actually registers

Renderer output being valid HTML proves nothing about whether Unraid will consume it. Test
the registration itself:

```bash
php -r '
$mytiles = [];
ob_start(); include "/usr/local/emhttp/plugins/backup-widget/BackupWidget.page"; ob_end_clean();
var_dump(isset($mytiles["backup-widget"]["column2"]));
'
```

Also confirm the fragment carries no `&&` - the deploy check parses it as XML:

```bash
php -r '... echo substr_count($t, "&&");'   # must be 0
```

## Forcing a refresh

```bash
bash /boot/config/plugins/backup-widget/scripts/duplicacy-coverage.sh   # ~2 min, hits 3 clouds
bash /boot/config/plugins/backup-widget/scripts/backup-inventory.sh     # ~30 s, local du
bash /boot/config/plugins/backup-widget/scripts/rclone-progress.sh      # one Dropbox call
bash /boot/config/plugins/backup-widget/scripts/rclone-live.sh          # instant, local
```

## Checking the live feed

```bash
export RCLONE_RC_USER=dash
export RCLONE_RC_PASS="$(cat /mnt/user/appdata/rclone/config/rc.secret)"
curl -s -u "dash:$RCLONE_RC_PASS" -X POST http://127.0.0.1:5572/core/stats
```

If that fails, the panel falls back to the cron-written figures and the activity line says
so. The usual cause is that the sync was started without `--rc`, which means the sync script
predates the rc change - restart it.

## Symptoms and causes

**Tile missing entirely.** Registration shape wrong, or a PHP parse error, or the file only
exists in flash after a boot that did not copy it. Run the registration test above.

**Whole dashboard blank.** A `.page` file declared a top-level variable that collided with
Unraid's own. Every `.page` shares one variable scope; only touch `$mytiles` and the
plugin's own prefixed variable, and keep all logic inside functions.

**Everything reads "Unchecked".** The 6-hourly coverage job has not run since boot. Run it
by hand.

**A dataset shows amber for a cloud it should not use.** `BW_SETS` in the config disagrees
with reality. A cloud absent for a dataset renders grey; a cloud present but with no snapshot
renders amber.

**A local dataset should remain visible while cloud backup is suspended.** Mark it Paused in
the settings page or add it to `BW_PAUSED`. The inventory collector still measures it, while
the renderers exclude it from backup gaps and the backup score.

**Mirror stuck at 99.x% and never green.** The coverage check's exclude filters do not match
the sync's. They must be identical, or a filtered-out file makes a complete mirror look
short.

**Progress bar jumps backwards after a restart.** Expected if the share-scoped calculation
has no inventory entry - it falls back to run-scoped figures. Run `backup-inventory.sh`.

## Stopping a running sync safely

Kill the supervising shell **first, with SIGKILL**, then the transfer. On SIGTERM, bash
finishes waiting on the current child and then starts the next share in its loop - which
abandons the current dataset part-way and silently moves on.

```bash
for p in $(ps -eo pid=,args= | awk '/[r]clone-dropbox-sync/ {print $1}'); do kill -9 "$p"; done
sleep 1
for p in $(ps -eo pid=,comm=,args= | awk '$2=="rclone" && /sync \/mnt\/user/ {print $1}'); do kill "$p"; done
```

Match on `comm` as well as the command line. A pattern like `pkill -f "serve webdav"` also
matches your own SSH command line and kills the session issuing it.

## Bumping the version

```bash
echo 2026.08.14 > VERSION
./tools/build-plg.sh
git commit -am "describe the change" && git tag v2026.08.14 && git push --follow-tags
```

Version format is `YYYY.MM.DD`; the build script refuses anything else, so the tag, the
manifest and the installed plugin cannot drift apart.
