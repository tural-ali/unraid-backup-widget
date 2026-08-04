<?PHP
/* Save handler for the backup-widget settings page.
 *
 * Writes exactly one file - /boot/config/plugins/backup-widget/config - in the
 * KEY="value" form that both PHP's parse_ini_file and bash's `source` accept.
 *
 * Security posture, deliberately narrow:
 *   - POST only, and a valid Unraid CSRF token is required. Without it the request
 *     is refused, because this runs as root like every emhttp page.
 *   - It executes NOTHING. No shell, no backup, no touching Duplicacy or rclone
 *     config. The only side effect is its own config file.
 *   - Every value is validated against a whitelist or a strict pattern before it
 *     is written. Share names are checked against the shares that actually exist,
 *     so a crafted POST cannot inject a path or a quote into a file that bash will
 *     later source.
 *
 * Nothing is refreshed here on purpose. bo_plan() reads the config live, so a
 * changed plan shows on the very next render; the cached coverage figures catch up
 * at their next pass, and until then a newly-ticked cloud reads "not checked yet"
 * in grey - which is true, and better than a page that pretends to know.
 */
require_once '/usr/local/emhttp/plugins/backup-widget/overview.php';

function bws_fail($msg, $code = 400) {
  http_response_code($code);
  header('Content-Type: text/plain; charset=utf-8');
  echo $msg, "\n";
  exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') bws_fail('POST required', 405);

/* CSRF: emhttp publishes the expected token in var.ini. A mismatch means the
   request did not come from the settings page in this session. */
$expected = '';
if (is_file('/usr/local/emhttp/state/var.ini')) {
  $v = @parse_ini_file('/usr/local/emhttp/state/var.ini');
  $expected = is_array($v) ? (string)($v['csrf_token'] ?? '') : '';
}
if ($expected === '' || !hash_equals($expected, (string)($_POST['csrf_token'] ?? ''))) {
  bws_fail('Invalid CSRF token', 403);
}

/* ---------- validate ---------- */
$shares = bo_shares();

/* Absolute path, no quote, backslash, newline or shell metacharacter. The file is
   sourced by bash, so anything that could terminate a quoted string is rejected
   rather than escaped. */
$cleanPath = function ($v, $fallback) {
  $v = trim((string)$v);
  if ($v === '') return $fallback;
  if (!preg_match('~^/[A-Za-z0-9._/\- ]{1,200}$~', $v)) return $fallback;
  return rtrim($v, '/');
};
$cleanNames = function ($v, $fallback) {
  $out = [];
  foreach (explode(',', (string)$v) as $n) {
    $n = trim($n);
    if ($n !== '' && preg_match('/^[A-Za-z0-9_-]{1,40}$/', $n)) $out[] = $n;
  }
  return $out ? implode(',', $out) : $fallback;
};
$cleanAddr = function ($v, $fallback) {
  $v = trim((string)$v);
  return preg_match('/^[A-Za-z0-9.\-]{0,64}:[0-9]{1,5}$/', $v) ? $v : $fallback;
};

$dupDir    = $cleanPath($_POST['DUP_DIR']    ?? '', '/mnt/user/appdata/duplicacy');
$rcloneDir = $cleanPath($_POST['RCLONE_DIR'] ?? '', '/mnt/user/appdata/rclone');
$stG       = $cleanNames($_POST['BW_STORAGE_G'] ?? '', 'gdrive');
$stM       = $cleanNames($_POST['BW_STORAGE_M'] ?? '', 'mailru');
$rcAddr    = $cleanAddr($_POST['BW_RC_ADDR'] ?? '', '127.0.0.1:5572');
$rcUser    = preg_match('/^[A-Za-z0-9_-]{1,32}$/', (string)($_POST['BW_RC_USER'] ?? ''))
             ? (string)$_POST['BW_RC_USER'] : 'dash';

/* Only shares that exist may appear anywhere. This is the check that makes the
   generated file safe for bash to source. */
$pick = function ($field) use ($shares) {
  $in = $_POST[$field] ?? [];
  if (!is_array($in)) return [];
  return array_values(array_intersect($shares, array_map('strval', $in)));
};
$selG = $pick('cloud_g');
$selM = $pick('cloud_m');
$selD = $pick('cloud_d');

$sets = [];
foreach ($shares as $s) {
  $st = [];
  if (in_array($s, $selG, true)) $st = array_merge($st, explode(',', $stG));
  if (in_array($s, $selM, true)) $st = array_merge($st, explode(',', $stM));
  if ($st) $sets[] = $s . ':' . implode(',', array_unique($st));
}

/* Display names, only where they differ from what would be derived anyway. */
$titles = [];
foreach ($shares as $s) {
  $t = trim((string)($_POST['title_' . $s] ?? ''));
  if ($t === '' || !preg_match('/^[\p{L}\p{N} .\'\-_&()]{1,48}$/u', $t)) continue;
  if ($t === ucwords(str_replace(['-', '_'], ' ', $s))) continue;
  $titles[] = $s . '=' . $t;
}

/* ---------- write ---------- */
$path = bo_conf_path();
if (!is_dir(dirname($path)) && !@mkdir(dirname($path), 0755, true)) {
  bws_fail('Cannot create ' . dirname($path), 500);
}

$body = "# backup-widget configuration\n"
      . "# Written by the settings page. Safe to edit by hand: every value is\n"
      . "# KEY=\"value\", which both PHP and bash can read.\n"
      . "# The plugin only READS from the paths below; it never writes to them.\n\n"
      . 'DUP_DIR="'      . $dupDir    . "\"\n"
      . 'RCLONE_DIR="'   . $rcloneDir . "\"\n\n"
      . 'BW_STORAGE_G="' . $stG       . "\"\n"
      . 'BW_STORAGE_M="' . $stM       . "\"\n\n"
      . "# repo:storages - a cloud absent for a share is reported as \"not configured\",\n"
      . "# in grey, and is never counted as a missing backup.\n"
      . 'BW_SETS="'      . implode(' ', $sets) . "\"\n"
      . "# shares the rclone mirror covers; must match SHARES in your sync script\n"
      . 'BW_MIRRORED="'  . implode(' ', $selD) . "\"\n\n"
      . 'BW_RC_ADDR="'   . $rcAddr . "\"\n"
      . 'BW_RC_USER="'   . $rcUser . "\"\n"
      . ($titles ? "\n" . 'BW_TITLES="' . implode(';', $titles) . "\"\n" : "");

/* Atomic replace: a half-written file that bash sources at the wrong moment is
   worse than the previous one. */
$tmp = $path . '.tmp';
if (@file_put_contents($tmp, $body) === false) bws_fail("Cannot write $tmp", 500);
@chmod($tmp, 0600);
if (!@rename($tmp, $path)) { @unlink($tmp); bws_fail("Cannot replace $path", 500); }

header('Location: /Utilities/BackupWidget?saved=1');
