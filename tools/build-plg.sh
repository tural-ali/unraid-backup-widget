#!/bin/bash
# Refresh plugin/backup-widget.plg from plugin/src/ and VERSION.
#
#   tools/build-plg.sh           rewrite every payload and the version entity
#   tools/build-plg.sh --check   exit 1 if the manifest differs from src/ or VERSION
#
# The manifest is the source of truth for everything except its payloads: the
# install and remove scripts and the CHANGES block are edited in the .plg itself.
# This rewrites each <FILE Name="/tmp/X.b64"> payload with base64 of its source
# and sets the version entity from VERSION, so the published manifest can never
# drift from src/. It used to regenerate the whole manifest from a template in
# this script, and the manifest installed on the author's server outgrew that
# template (new collectors, new install steps) without anything noticing.
#
# Payload sources:
#   backup-widget.cron, config.example   plugin/src/boot/X
#   *.sh                                 plugin/src/usr/local/emhttp/plugins/backup-widget/scripts/X
#   anything else                        plugin/src/usr/local/emhttp/plugins/backup-widget/X
#
# Why base64 rather than a .txz: a self-contained .plg installs from flash without
# fetching a second artifact, and the payload is PHP and JavaScript full of "<",
# ">" and "&". A .plg is XML; base64 is inert inside it.
#
# A new collector script also needs its own FILE entry and a line in the install
# loop. This refuses to build while one is missing, rather than ship a manifest
# that silently leaves it out - the cron once called backup-history.sh, which the
# manifest never installed, and that is invisible on a box where the file exists.
set -eu
cd "$(dirname "$0")/.."

exec python3 -I - "$@" <<'PY'
import argparse, base64, re, sys
import xml.dom.minidom
from pathlib import Path

ROOT = Path.cwd()
PLG = ROOT / 'plugin/backup-widget.plg'
BOOT = ROOT / 'plugin/src/boot'
WEB = ROOT / 'plugin/src/usr/local/emhttp/plugins/backup-widget'
ENTRY = re.compile(r'(<FILE Name="/tmp/([^"]+)\.b64">\s*<INLINE>\s*)(.*?)(\s*</INLINE>)', re.S)
VERSION_ENTITY = re.compile(r'(<!ENTITY version\s+")([^"]*)(")')


def encode(data, old_body):
    # Keep the manifest's own layout: wrapped at 76 if it was, one line if not.
    if '\n' in old_body.strip():
        return base64.encodebytes(data).decode().rstrip('\n')
    return base64.b64encode(data).decode()


def source(name):
    if name in ('backup-widget.cron', 'config.example'):
        return BOOT / name
    return WEB / 'scripts' / name if name.endswith('.sh') else WEB / name


ap = argparse.ArgumentParser()
ap.add_argument('--check', action='store_true')
args = ap.parse_args()

version = (ROOT / 'VERSION').read_text().strip()
if not re.fullmatch(r'\d{4}\.\d{2}\.\d{2}(\.\d+)?', version):
    sys.exit(f"VERSION must be YYYY.MM.DD[.N], got '{version}'")

text = PLG.read_text()
names = [m.group(2) for m in ENTRY.finditer(text)]
missing = [n for n in names if not source(n).is_file()]
if missing:
    sys.exit(f'no source for: {", ".join(missing)}')
loose = sorted(p.name for p in (WEB / 'scripts').glob('*.sh') if p.name not in names)
if loose:
    sys.exit(f'scripts with no FILE entry in the manifest: {", ".join(loose)}')
# The install script, minus the staging paths, which name every payload anyway.
install = re.sub(r'/tmp/\S+?\.b64', '', text.split('<![CDATA[', 1)[-1])
unlooped = [n for n in names if n.endswith('.sh') and not re.search(rf'\b{re.escape(n)}\b', install)]
if unlooped:
    sys.exit(f'not in the install loop: {", ".join(unlooped)}')
cron_refs = set(re.findall(r'scripts/([a-z0-9-]+\.sh)', source('backup-widget.cron').read_text()))
uninstalled = sorted(cron_refs - set(names))
if uninstalled:
    sys.exit(f'the cron calls scripts the manifest does not install: {", ".join(uninstalled)}')

if args.check:
    stale = [m.group(2) for m in ENTRY.finditer(text)
             if base64.b64decode(''.join(m.group(3).split())) != source(m.group(2)).read_bytes()]
    current = VERSION_ENTITY.search(text).group(2)
    if current != version:
        stale.append(f'version ({current}, VERSION says {version})')
    if stale:
        sys.exit(f'manifest is stale for: {", ".join(stale)}; run tools/build-plg.sh')
    xml.dom.minidom.parseString(text)
    print(f'manifest matches src/ and VERSION ({version}), {len(names)} payloads, XML well-formed')
    sys.exit(0)

text = ENTRY.sub(lambda m: m.group(1) + encode(source(m.group(2)).read_bytes(), m.group(3)) + m.group(4), text)
text, n = VERSION_ENTITY.subn(rf'\g<1>{version}\g<3>', text)
if n != 1:
    sys.exit('version entity not found')
xml.dom.minidom.parseString(text)
PLG.write_text(text)
print(f'wrote {PLG.relative_to(ROOT)}: {len(names)} payloads, version {version}, XML well-formed')
PY
