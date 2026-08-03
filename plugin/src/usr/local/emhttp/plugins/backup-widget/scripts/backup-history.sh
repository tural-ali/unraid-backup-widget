#!/bin/bash
# Record one history sample per dataset, for the tile's sparkline.
#
# Runs just after the coverage collector so it samples fresh data. The work is in
# PHP because bo_record_history() reuses bo_state() - the same interpreter the
# renderers use - rather than reimplementing "is this dataset fully covered" in
# bash, where it would drift.
#
# Writes to /boot/config/plugins/backup-widget/history.tsv, on flash, because
# history that resets at every reboot is not history.
set -u
PLUGIN=/usr/local/emhttp/plugins/backup-widget/overview.php
[ -f "$PLUGIN" ] || exit 0
php -r 'require $argv[1]; exit(bo_record_history() ? 0 : 1);' "$PLUGIN"
