#!/bin/bash
# Generate plugin/backup-widget.plg from plugin/src/.
#
# Why the files are embedded base64 rather than shipped as a .txz:
#
#   1. This is a PRIVATE repository. Unraid's plugin installer fetches URLs
#      anonymously, so a raw.githubusercontent.com link to a txz would 404. An
#      entirely self-contained .plg installs from the flash drive with no network
#      access at all.
#   2. The payload is PHP and JavaScript full of "<", ">" and "&". A .plg is XML,
#      and Unraid's own installer parses it as such. Embedding source verbatim -
#      even inside CDATA - is a standing invitation to break the manifest the
#      first time someone writes "]]>" or an unescaped ampersand. Base64 is inert.
#
# Versioning is date-based, matching Unraid plugin convention (YYYY.MM.DD). The
# value comes from the VERSION file so the tag, the manifest and the installed
# plugin can never disagree.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(tr -d ' \n' < VERSION)
SRC=plugin/src
OUT=plugin/backup-widget.plg

[ -d "$SRC" ] || { echo "no $SRC"; exit 1; }
case "$VERSION" in
  [0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]) ;;
  *) echo "VERSION must be YYYY.MM.DD, got '$VERSION'"; exit 1 ;;
esac

# Files that land in the web-served plugin directory. Copied to flash by the
# installer and re-copied to RAM on every boot, because /usr/local/emhttp is
# tmpfs and anything written there alone disappears.
WEB="overview.php overview-widget.php overview-live.php overview-poll.php
     widget-poll.php settings-save.php
     BackupOverview.page BackupWidget.page BackupSettings.page"
# Every script the shipped cron references MUST be listed here. backup-history.sh
# was added to the cron and to src/ but not to this list, so the manifest wrote a
# cron entry pointing at a file it never installed - invisible on the machine it
# was developed on, because the flash copy was already there by hand.
SCRIPTS="duplicacy-status.sh duplicacy-coverage.sh backup-inventory.sh
         rclone-live.sh rclone-progress.sh backup-history.sh"

b64() { base64 < "$1" | tr -d '\n'; }

{
cat <<HEADER
<?xml version='1.0' standalone='yes'?>
<!DOCTYPE PLUGIN [
<!ENTITY name      "backup-widget">
<!ENTITY author    "tural-ali">
<!ENTITY version   "$VERSION">
<!ENTITY launch    "Tools/BackupOverview">
<!ENTITY github    "tural-ali/unraid-backup-widget">
<!ENTITY plgdir    "/boot/config/plugins/&name;">
<!ENTITY emhttpdir "/usr/local/emhttp/plugins/&name;">
<!-- pluginURL is what gives Unraid an update path: it re-fetches this manifest to
     compare versions. Without it the plugin installs but can never be updated,
     which also disqualifies it from Community Applications. It only became
     possible once the repository was public - Unraid's installer fetches
     anonymously, so a private raw URL 404s. -->
<!ENTITY pluginURL "https://raw.githubusercontent.com/&github;/main/plugin/&name;.plg">
]>

<PLUGIN name="&name;" author="&author;" version="&version;" pluginURL="&pluginURL;"
        launch="&launch;" min="6.12.0"
        support="https://github.com/tural-ali/unraid-backup-widget/issues"
        icon="shield">

<CHANGES>
See docs/CHANGELOG in the repository. Versions are dates: &version;.
</CHANGES>

HEADER

# ---- payload, one FILE block per source file, base64 to a staging path
for f in $WEB; do
  printf '<FILE Name="/tmp/%s.b64">\n<INLINE>\n%s\n</INLINE>\n</FILE>\n\n' \
    "$f" "$(b64 "$SRC/usr/local/emhttp/plugins/backup-widget/$f")"
done
for f in $SCRIPTS; do
  printf '<FILE Name="/tmp/%s.b64">\n<INLINE>\n%s\n</INLINE>\n</FILE>\n\n' \
    "$f" "$(b64 "$SRC/usr/local/emhttp/plugins/backup-widget/scripts/$f")"
done
printf '<FILE Name="/tmp/backup-widget.cron.b64">\n<INLINE>\n%s\n</INLINE>\n</FILE>\n\n' \
  "$(b64 "$SRC/boot/backup-widget.cron")"
printf '<FILE Name="/tmp/config.example.b64">\n<INLINE>\n%s\n</INLINE>\n</FILE>\n\n' \
  "$(b64 "$SRC/boot/config.example")"

cat <<'INSTALL'
<FILE Run="/bin/bash">
<INLINE>
<![CDATA[
set -e
PLG=/boot/config/plugins/backup-widget
WEB=/usr/local/emhttp/plugins/backup-widget
mkdir -p "$PLG/scripts" "$WEB"

decode() {  # $1 = basename, $2 = destination, $3 = mode
  [ -f "/tmp/$1.b64" ] || { echo "ERROR: /tmp/$1.b64 missing"; exit 1; }
  base64 -d < "/tmp/$1.b64" > "$2"
  chmod "$3" "$2"
  rm -f "/tmp/$1.b64"
}

for f in overview.php overview-widget.php overview-live.php overview-poll.php \
         widget-poll.php settings-save.php \
         BackupOverview.page BackupWidget.page BackupSettings.page; do
  decode "$f" "$PLG/$f" 600
  # /usr/local/emhttp is tmpfs: the flash copy is the source of truth and this
  # second copy is what the webserver actually reads until the next boot.
  install -m 600 "$PLG/$f" "$WEB/$f"
done

for f in duplicacy-status.sh duplicacy-coverage.sh backup-inventory.sh \
         rclone-live.sh rclone-progress.sh; do
  decode "$f" "$PLG/scripts/$f" 755
done

decode backup-widget.cron /boot/config/plugins/dynamix/backup-widget.cron 600
# Never clobber an existing config; ship the example alongside it.
decode config.example "$PLG/config.example" 600

update_cron >/dev/null 2>&1 || /usr/local/sbin/update_cron >/dev/null 2>&1 || true

echo ""
echo "backup-widget installed."
echo "  Dashboard tile : column 2"
echo "  Full page      : Tools -> Backup Overview"
echo "  Settings       : Settings -> Utilities -> Backup Widget"
echo ""
echo "It reports on backups; it does not run them. Duplicacy and rclone stay"
echo "under your control. Edit $PLG/config if your layout differs from the"
echo "defaults in config.example."
]]>
</INLINE>
</FILE>

<FILE Run="/bin/bash" Method="remove">
<INLINE>
<![CDATA[
rm -rf /usr/local/emhttp/plugins/backup-widget
rm -f  /boot/config/plugins/dynamix/backup-widget.cron
update_cron >/dev/null 2>&1 || true
# Deliberately keeps /boot/config/plugins/backup-widget so a reinstall does not
# lose the operator's config file. Remove it by hand to purge completely.
echo "backup-widget removed. Config kept at /boot/config/plugins/backup-widget."
]]>
</INLINE>
</FILE>

</PLUGIN>
INSTALL
} > "$OUT"

# Guard: every script the cron invokes must be in the manifest. This exact
# mismatch shipped once - the cron called backup-history.sh and the manifest did
# not contain it, which is undetectable on a box where the file already exists.
missing=0
for s in $(grep -oE 'scripts/[a-z-]+\.sh' "$SRC/boot/backup-widget.cron" | sed 's|scripts/||' | sort -u); do
  if ! grep -q "/tmp/$s.b64" "$OUT"; then
    echo "  ERROR: cron references $s but the manifest does not install it"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

echo "  wrote $OUT  ($(wc -c < "$OUT") bytes, version $VERSION)"

# The manifest must be well-formed XML or Unraid's installer fails obscurely.
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$OUT" && echo "  XML well-formed"
else
  python3 - "$OUT" <<'PY'
import sys, xml.dom.minidom
xml.dom.minidom.parse(sys.argv[1])
print("  XML well-formed")
PY
fi
