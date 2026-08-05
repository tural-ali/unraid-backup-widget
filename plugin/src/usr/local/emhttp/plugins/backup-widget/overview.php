<?PHP
/* Backup overview page - full-width status panel for the whole backup estate.
 *
 * Rendering lives here and is shared with overview-poll.php, which serves the
 * 60s refresh, so the first paint and every update come from one code path and
 * cannot drift.
 *
 * Every figure is read from a cached ini written by cron. Nothing here shells
 * out, walks the filesystem or calls a cloud: the page must render in
 * milliseconds and must not hammer Dropbox each time a browser tab is open.
 *
 *   backup-inventory.ini      6h   per-dataset bytes and file counts (local du)
 *   duplicacy-coverage.ini    6h   newest snapshot per repo per storage
 *   duplicacy.ini             1m   live Duplicacy progress, parsed from its log
 *   rclone-dropbox.ini        -    written by the sync script itself
 *   rclone-dropbox-live.ini   1m   files copied, from the local sync log
 *   rclone-progress.ini       5m   real bytes/rate/ETA, measured against Dropbox
 *
 * Two tools, two kinds of copy, and the page keeps them distinct: Duplicacy
 * writes versioned encrypted chunks to Google Drive and mail.ru; rclone mirrors
 * plain files to Dropbox. They fail differently and restore differently, so a
 * green cell means different things and says which tool produced it.
 */

if (!function_exists('bo_ini')) {
  function bo_ini($path) {
    $p = @parse_ini_file($path);
    return is_array($p) ? $p : [];
  }
}

if (!function_exists('bo_conf_path')) {
  function bo_conf_path() { return '/boot/config/plugins/backup-widget/config'; }
}

if (!function_exists('bo_conf')) {
  /* Configuration, read from one file that both PHP and bash can consume.
   *
   * Every value is KEY="value", which parse_ini_file understands and `source`
   * accepts unchanged - so the settings page, the renderers and the shell
   * collectors all read the same file with no duplicate parser to drift.
   *
   * Absent file or absent key falls back to the shipped default. That matters:
   * this file used to exist as config.example only, with nothing reading it, and
   * the dataset list was hardcoded in three places. A missing config must degrade
   * to working defaults, never to an empty dashboard.
   */
  function bo_conf($key = null, $default = null) {
    static $c = null;
    if ($c === null) {
      $c = @parse_ini_file(bo_conf_path());
      if (!is_array($c)) $c = [];
    }
    if ($key === null) return $c;
    /* An ABSENT key takes the default. A key that is present but empty means the
       operator chose nothing, and must stay empty.
       Conflating the two meant unticking every cloud in the settings page handed
       back the shipped defaults - so "monitor nothing" was indistinguishable from
       "never configured", and the dashboard invented five datasets the operator
       had explicitly removed. */
    if (!array_key_exists($key, $c)) return $default;
    return trim((string)$c[$key]);
  }
}

if (!function_exists('bo_dup_dir')) {
  function bo_dup_dir()    { return rtrim(bo_conf('DUP_DIR', '/mnt/user/appdata/duplicacy'), '/'); }
  function bo_rclone_dir() { return rtrim(bo_conf('RCLONE_DIR', '/mnt/user/appdata/rclone'), '/'); }
  function bo_rc_addr()    { return bo_conf('BW_RC_ADDR', '127.0.0.1:5572'); }
  function bo_rc_user()    { return bo_conf('BW_RC_USER', 'dash'); }
}

if (!function_exists('bo_shares')) {
  /* Shares that exist and could be monitored. Excludes Unraid's own and anything
     the operator has told us to ignore, so the settings page offers a sane list
     rather than every directory under /mnt/user. */
  function bo_shares() {
    $skip = ['system', 'domains', 'isos', 'timemachine'];
    $out = [];
    foreach (glob('/mnt/user/*', GLOB_ONLYDIR) ?: [] as $d) {
      $n = basename($d);
      if (in_array($n, $skip, true)) continue;
      if ($n[0] === '.') continue;
      $out[] = $n;
    }
    sort($out);
    return $out;
  }
}

if (!function_exists('bo_title_for')) {
  /* "raw-photos" -> "Raw Photos", unless the operator named it in BW_TITLES. */
  function bo_title_for($share) {
    foreach (explode(';', bo_conf('BW_TITLES', '')) as $pair) {
      if ($pair === '') continue;
      [$k, $v] = array_pad(explode('=', $pair, 2), 2, '');
      if ($k === $share && $v !== '') return $v;
    }
    return ucwords(str_replace(['-', '_'], ' ', $share));
  }
}

if (!function_exists('bo_icon_for')) {
  /* A glyph guessed from the name, overridable. Only cosmetic, so guessing is
     fine - but guessing badly is not, hence the explicit list first. */
  function bo_icon_for($share) {
    foreach (explode(';', bo_conf('BW_ICONS', '')) as $pair) {
      if ($pair === '') continue;
      [$k, $v] = array_pad(explode('=', $pair, 2), 2, '');
      if ($k === $share && $v !== '') return $v;
    }
    $s = strtolower($share);
    if (strpos($s, 'photo') !== false || strpos($s, 'raw') !== false)  return 'image';
    if (strpos($s, 'video') !== false || strpos($s, 'movie') !== false) return 'video';
    if (strpos($s, 'paper') !== false || strpos($s, 'doc') !== false)   return 'doc';
    if (strpos($s, 'immich') !== false || strpos($s, 'phone') !== false) return 'phone';
    if (strpos($s, 'appdata') !== false || strpos($s, 'config') !== false) return 'gear';
    return 'files';
  }
}

if (!function_exists('bo_tint_for')) {
  function bo_tint_for($share) {
    $map = ['image' => '#16a34a', 'video' => '#7c3aed', 'doc' => '#ea580c',
            'phone' => '#2563eb', 'gear'  => '#64748b', 'files' => '#0891b2'];
    return $map[bo_icon_for($share)] ?? '#64748b';
  }
}

if (!function_exists('bo_storage_map')) {
  /* Which cloud key each Duplicacy storage name belongs to.
     BW_STORAGE_G / _M name the storages; anything else is ignored. Defaults match
     the layout this was written against. */
  function bo_storage_map() {
    return [
      'g' => array_filter(array_map('trim', explode(',', bo_conf('BW_STORAGE_G', 'gdrive')))),
      'm' => array_filter(array_map('trim', explode(',', bo_conf('BW_STORAGE_M', 'mailru')))),
    ];
  }
}

if (!function_exists('bo_sets')) {
  /* repo:storage,storage  parsed into [share => [storage, ...]]. */
  function bo_sets() {
    $raw = bo_conf('BW_SETS', 'raw-photos:gdrive,mailru videos:gdrive paperless:gdrive,mailru appdata:gdrive,mailru immich:gdrive');
    $out = [];
    if (trim($raw) === '') return $out;
    foreach (preg_split('/\s+/', trim($raw)) as $entry) {
      if ($entry === '' || strpos($entry, ':') === false) continue;
      [$share, $stores] = explode(':', $entry, 2);
      $out[$share] = array_values(array_filter(array_map('trim', explode(',', $stores))));
    }
    return $out;
  }
}

if (!function_exists('bo_mirrored')) {
  function bo_mirrored() {
    $raw = trim(bo_conf('BW_MIRRORED', 'videos raw-photos'));
    if ($raw === '') return [];
    return array_values(array_filter(preg_split('/\s+/', $raw)));
  }
}

if (!function_exists('bo_paused')) {
  function bo_paused() {
    $raw = trim(bo_conf('BW_PAUSED', ''));
    if ($raw === '') return [];
    return array_values(array_filter(preg_split('/\s+/', $raw)));
  }
}

if (!function_exists('bo_bytes')) {
  /* Decimal units, matching how cloud providers quote quota - Dropbox's "3 TB"
     is 3.002 TiB, and showing TiB here would make every figure disagree with
     the provider's own dashboard. */
  function bo_bytes($b) {
    $b = (float)$b;
    if ($b <= 0) return '0 B';
    $u = ['B','KB','MB','GB','TB','PB'];
    $i = (int)floor(log($b, 1000));
    if ($i < 0) $i = 0;
    if ($i > 5) $i = 5;
    $v = $b / pow(1000, $i);
    $d = ($i >= 3 && $v < 10) ? 2 : ($i >= 2 ? ($v < 100 ? 1 : 0) : 0);
    return number_format($v, $d) . ' ' . $u[$i];
  }
}

if (!function_exists('bo_rate')) {
  function bo_rate($bps) {
    $bps = (float)$bps;
    if ($bps <= 0) return '';
    return bo_bytes($bps) . '/s';
  }
}

if (!function_exists('bo_parse_stamp')) {
  /* Coverage stores "DD/MM HH:MM" with no year, so infer it: anything that
     lands in the future belongs to last year. Without this, a backup taken on
     31/12 reads as eleven months in the future every January. */
  function bo_parse_stamp($s) {
    if (!preg_match('~^([0-9]{2})/([0-9]{2}) ([0-9]{2}):([0-9]{2})$~', trim($s), $m)) return null;
    $now = time();
    $ts  = mktime((int)$m[3], (int)$m[4], 0, (int)$m[2], (int)$m[1], (int)date('Y', $now));
    if ($ts > $now + 86400) $ts = mktime((int)$m[3], (int)$m[4], 0, (int)$m[2], (int)$m[1], (int)date('Y', $now) - 1);
    return $ts;
  }
}

if (!function_exists('bo_ago')) {
  function bo_ago($ts) {
    if (!$ts) return '';
    $d = time() - $ts;
    if ($d < 90)     return 'just now';
    if ($d < 5400)   return round($d / 60) . 'm ago';
    if ($d < 172800) return round($d / 3600) . 'h ago';
    return round($d / 86400) . 'd ago';
  }
}

if (!function_exists('bo_when')) {
  function bo_when($ts) {
    if (!$ts) return '&#8211;';
    return (date('Y-m-d', $ts) === date('Y-m-d'))
      ? 'Today at ' . date('H:i', $ts)
      : date('d M', $ts) . ' at ' . date('H:i', $ts);
  }
}

if (!function_exists('bo_icon')) {
  /* Inline SVG only. The panel renders on a LAN-only box, and a remote asset
     would drop its labels exactly when WAN is down - which is when someone is
     most likely to be looking at a backup dashboard. */
  function bo_icon($k, $px = 16, $colour = 'currentColor') {
    $s = "width='$px' height='$px' viewBox='0 0 24 24' fill='none' stroke='$colour'"
       . " stroke-width='2' stroke-linecap='round' stroke-linejoin='round'";
    switch ($k) {
      case 'shield':  return "<svg $s><path d='M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z'/><path d='M9 12l2 2 4-4'/></svg>";
      case 'alert':   return "<svg $s><circle cx='12' cy='12' r='10'/><path d='M12 8v4M12 16h.01'/></svg>";
      case 'sync':    return "<svg $s><path d='M21 12a9 9 0 01-9 9 9 9 0 01-7.4-3.9'/><path d='M3 12a9 9 0 019-9 9 9 0 017.4 3.9'/><path d='M21 3v4h-4M3 21v-4h4'/></svg>";
      case 'db':      return "<svg $s><ellipse cx='12' cy='6' rx='8' ry='3'/><path d='M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6'/><path d='M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3'/></svg>";
      case 'check':   return "<svg $s><circle cx='12' cy='12' r='10'/><path d='M8 12.5l2.5 2.5L16 9.5'/></svg>";
      case 'cross':   return "<svg $s><circle cx='12' cy='12' r='10'/><path d='M15 9l-6 6M9 9l6 6'/></svg>";
      case 'dash':    return "<svg $s><path d='M5 12h14'/></svg>";
      case 'clock':   return "<svg $s><circle cx='12' cy='12' r='9'/><path d='M12 7v5l3 2'/></svg>";
      case 'pulse':   return "<svg $s><path d='M3 12h4l3 8 4-16 3 8h4'/></svg>";
      case 'files':   return "<svg $s><rect x='3' y='4' width='18' height='16' rx='2'/><path d='M3 10h18'/></svg>";
      case 'image':   return "<svg $s><rect x='3' y='3' width='18' height='18' rx='2'/><circle cx='8.5' cy='9' r='1.5'/><path d='M21 16l-5-5-11 10'/></svg>";
      case 'video':   return "<svg $s><rect x='2' y='6' width='13' height='12' rx='2'/><path d='M15 11l7-4v10l-7-4z'/></svg>";
      case 'doc':     return "<svg $s><path d='M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8z'/><path d='M14 3v5h5'/></svg>";
      case 'phone':   return "<svg $s><rect x='6' y='2' width='12' height='20' rx='2'/><path d='M11 18h2'/></svg>";
      case 'gear':    return "<svg $s><circle cx='12' cy='12' r='3'/><path d='M19.4 15a1.7 1.7 0 00.3 1.9l.1.1a2 2 0 01-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.9-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 01-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.9.3l-.1.1a2 2 0 01-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.9 1.7 1.7 0 00-1.5-1H3a2 2 0 010-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.9l-.1-.1a2 2 0 012.8-2.8l.1.1a1.7 1.7 0 001.9.3H10a1.7 1.7 0 001-1.5V3a2 2 0 014 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.9-.3l.1-.1a2 2 0 012.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.9V10a1.7 1.7 0 001.5 1H21a2 2 0 010 4h-.1a1.7 1.7 0 00-1.5 1z'/></svg>";
      case 'cloud':   return "<svg $s><path d='M18 17h-8a5 5 0 110-10 6 6 0 0111.3 2.3A4 4 0 0118 17z'/></svg>";
      case 'refresh': return "<svg $s><path d='M21 12a9 9 0 11-3-6.7'/><path d='M21 4v5h-5'/></svg>";
      case 'chev':    return "<svg $s><path d='M6 9l6 6 6-6'/></svg>";
    }
    return '';
  }
}

if (!function_exists('bo_brand')) {
  /* Provider marks, brand-coloured so the three storage columns stay
     distinguishable at a glance in either dashboard theme. */
  function bo_brand($k, $px = 15) {
    switch ($k) {
      case 'g':
        return "<svg width='$px' height='$px' viewBox='0 0 87.3 78' role='img' aria-label='Google Drive'>"
          . "<path fill='#0066da' d='M6.6 66.85l3.85 6.65c.8 1.4 1.95 2.5 3.3 3.3l13.75-23.8H0c0 1.55.4 3.1 1.2 4.5z'/>"
          . "<path fill='#00ac47' d='M43.65 25L29.9 1.2c-1.35.8-2.5 1.9-3.3 3.3l-25.4 44A9.06 9.06 0 000 53h27.5z'/>"
          . "<path fill='#ea4335' d='M73.55 76.8c1.35-.8 2.5-1.9 3.3-3.3l1.6-2.75 7.65-13.25c.8-1.4 1.2-2.95 1.2-4.5H59.8l5.85 11.5z'/>"
          . "<path fill='#00832d' d='M43.65 25L57.4 1.2C56.05.4 54.5 0 52.9 0H34.4c-1.6 0-3.15.45-4.5 1.2z'/>"
          . "<path fill='#2684fc' d='M59.8 53H27.5L13.75 76.8c1.35.8 2.9 1.2 4.5 1.2h50.8c1.6 0 3.15-.45 4.5-1.2z'/>"
          . "<path fill='#ffba00' d='M73.4 26.5l-12.7-22c-.8-1.4-1.95-2.5-3.3-3.3L43.65 25l16.15 28h27.45c0-1.55-.4-3.1-1.2-4.5z'/></svg>";
      case 'd':
        return "<svg width='$px' height='$px' viewBox='0 0 24 24' role='img' aria-label='Dropbox'>"
          . "<path fill='#0061ff' d='M6 1.807L0 5.629l6 3.822 6.001-3.822L6 1.807zM18 1.807l-6 3.822 6 3.822 6-3.822-6-3.822zM0 13.274l6 3.822 6.001-3.822L6 9.452l-6 3.822zM18 9.452l-6 3.822 6 3.822 6-3.822-6-3.822zM6 18.371l6.001 3.822 6-3.822-6-3.822L6 18.371z'/></svg>";
      case 'm':
        return "<svg width='$px' height='$px' viewBox='0 0 24 24' role='img' aria-label='mail.ru'>"
          . "<path fill='#005ff9' d='M15.61 12a3.61 3.61 0 11-7.22 0 3.61 3.61 0 017.22 0zM12 0a12 12 0 100 24 11.94 11.94 0 008.48-3.51l-1.41-1.41A9.96 9.96 0 0112 22C6.48 22 2 17.52 2 12S6.48 2 12 2s10 4.48 10 10c0 1.38-.28 2.7-.79 3.9-.24.36-.6.6-1.02.6-.66 0-1.19-.53-1.19-1.19V12a7 7 0 10-2.05 4.95 3.39 3.39 0 002.74 1.35c1.05 0 1.98-.52 2.55-1.31A11.9 11.9 0 0024 12C24 5.37 18.63 0 12 0z'/></svg>";
    }
    return '';
  }
}

if (!function_exists('bo_rc')) {
  /* Live transfer stats straight from the running rclone via its rc server.
   *
   * This is what makes the panel update like a CPU graph: cron files were the
   * only source before, and the fastest of those was a minute, with byte figures
   * needing a Dropbox listing call that cannot run every second. rc answers
   * in-process, instantly, as often as asked.
   *
   * Hard 1s timeout and a silent null on any failure: a dashboard must never
   * hang because a transfer is wedged. Absence of rc just means the panel falls
   * back to the cron-written figures.
   */
  function bo_rc() {
    static $cached = false, $val = null;
    if ($cached) return $val;
    $cached = true;

    $pw = @file_get_contents(bo_rclone_dir() . '/config/rc.secret');
    if ($pw === false) return null;
    $pw = trim($pw);

    $ctx = stream_context_create(['http' => [
      'method'        => 'POST',
      'header'        => "Authorization: Basic " . base64_encode(bo_rc_user() . ":$pw") . "\r\n"
                       . "Content-Length: 0\r\n",
      'timeout'       => 1.0,
      'ignore_errors' => true,
    ]]);
    $raw = @file_get_contents('http://' . bo_rc_addr() . '/core/stats', false, $ctx);
    if ($raw === false) return null;
    $j = json_decode($raw, true);
    if (!is_array($j) || !isset($j['totalBytes'])) return null;

    /* Which share is in flight, taken from the transfer list rather than the ini
       so it is correct the instant rclone moves on to the next one. */
    $share = '';
    foreach (($j['transferring'] ?? []) as $t) {
      if (!empty($t['srcFs']) && preg_match('~/mnt/user/([^/]+)~', $t['srcFs'], $m)) { $share = $m[1]; break; }
    }

    $done  = (float)($j['bytes'] ?? 0);
    $total = (float)($j['totalBytes'] ?? 0);
    $val = [
      'share'   => $share,
      'done'    => $done,
      'total'   => $total,
      'pct'     => $total > 0 ? min(100, $done * 100 / $total) : 0,
      'speed'   => (float)($j['speed'] ?? 0),
      'eta'     => (int)($j['eta'] ?? 0),
      'errors'  => (int)($j['errors'] ?? 0),
      'checks'  => (int)($j['checks'] ?? 0),
      'xfers'   => (int)($j['totalTransfers'] ?? 0),
      'elapsed' => (float)($j['elapsedTime'] ?? 0),
      'files'   => array_slice(array_map(function($t) {
                     return ['name' => basename($t['name'] ?? ''),
                             'pct'  => (float)($t['percentage'] ?? 0),
                             'speed'=> (float)($t['speed'] ?? 0)];
                   }, $j['transferring'] ?? []), 0, 4),
    ];
    return $val;
  }
}

if (!function_exists('bo_dur')) {
  function bo_dur($secs) {
    $secs = (int)$secs;
    if ($secs <= 0) return '';
    if ($secs >= 86400) return floor($secs / 86400) . 'd ' . floor(($secs % 86400) / 3600) . 'h';
    if ($secs >= 3600)  return floor($secs / 3600) . 'h ' . floor(($secs % 3600) / 60) . 'm';
    if ($secs >= 60)    return floor($secs / 60) . 'm';
    return $secs . 's';
  }
}


if (!function_exists('bo_quota')) {
  /* Per-provider headroom, from the hourly collector.
   *
   * Free is taken as reported, not computed as total minus used. On Google Drive
   * they differ: Google Photos and Family sharing draw on the same quota and
   * appear as "other", so total-minus-used overstates what is actually available
   * by well over a terabyte here.
   *
   * A provider with no usable figures returns null rather than zeroes - drawing a
   * full bar because a call failed would be a false alarm about the one thing this
   * panel exists to report honestly.
   */
  function bo_quota() {
    static $q = null;
    if ($q !== null) return $q;
    $i = bo_ini('/var/local/emhttp/cloud-quota.ini');
    $q = ['updated' => $i['q_updated'] ?? ''];
    foreach (['g', 'd', 'm'] as $k) {
      $state = $i["q_{$k}_state"] ?? '';
      $total = (float)($i["q_{$k}_total"] ?? 0);
      $free  = (float)($i["q_{$k}_free"]  ?? 0);
      /* 'stale' carries the previous run's figures because this run's call failed.
         Those are still worth showing - a provider's free space does not move much
         in an hour - but the renderers must be able to say so, hence the flag and
         the measurement time rather than a silent substitution. */
      if (($state !== 'ok' && $state !== 'stale') || $total <= 0) { $q[$k] = null; continue; }
      $q[$k] = [
        'total' => $total,
        'used'  => (float)($i["q_{$k}_used"] ?? 0),
        'free'  => $free,
        'other' => (float)($i["q_{$k}_other"] ?? 0),
        /* Fullness from free, for the same reason as above. */
        'pct'   => (int)round((1 - $free / $total) * 100),
        'stale' => $state === 'stale',
        'at'    => (int)($i["q_{$k}_at"] ?? 0),
      ];
    }
    return $q;
  }
}

if (!function_exists('bo_quota_colour')) {
  /* Amber under 15% free, red under 5%. Dropbox is the one with a hard ceiling
     that cannot be upgraded, so the warning needs to arrive with time to act. */
  function bo_quota_colour($q) {
    $p = bo_pal();
    if (!$q) return $p['grey'];
    $frac = $q['total'] > 0 ? $q['free'] / $q['total'] : 0;
    if ($frac < 0.05) return $p['red'];
    if ($frac < 0.15) return $p['amber'];
    return $p['green'];
  }
}

if (!function_exists('bo_plan')) {
  /* Which datasets go to which clouds, built from the config file.
   *
   * This used to be a hardcoded array duplicated against the collectors' own
   * hardcoded list - two sources of truth for the same fact, in a plugin whose
   * central claim is that it has one. Now both read bo_sets()/bo_mirrored().
   *
   * A cloud absent for a dataset is a deliberate decision, NOT a missing backup,
   * and renders grey. Dropbox is listed only for shares in BW_MIRRORED.
   */
  function bo_plan() {
    $sets     = bo_sets();
    $mirrored = bo_mirrored();
    $paused   = bo_paused();
    $map      = bo_storage_map();

    /* Display order: configured targets, mirror-only shares, then deliberately
       paused datasets. Paused rows remain visible but never lower the score. */
    $order = array_keys($sets);
    foreach ($mirrored as $m) if (!in_array($m, $order, true)) $order[] = $m;
    foreach ($paused as $p) if (!in_array($p, $order, true)) $order[] = $p;

    $plan = [];
    foreach ($order as $share) {
      if (!is_dir('/mnt/user/' . $share)) continue;   // configured but gone
      $isPaused = in_array($share, $paused, true);
      $targets = [];
      if (!$isPaused) {
        foreach ($sets[$share] ?? [] as $storage) {
          foreach (['g', 'm'] as $k) {
            if (in_array($storage, $map[$k], true)) $targets[$k] = 'duplicacy';
          }
        }
        if (in_array($share, $mirrored, true)) $targets['d'] = 'rclone';
      }
      if (!$targets && !$isPaused) continue;          // nothing to report on

      $plan[$share] = [
        'key'     => 'cov_' . str_replace('-', '_', $share),
        'title'   => bo_title_for($share),
        'icon'    => bo_icon_for($share),
        'tint'    => bo_tint_for($share),
        'targets' => $targets,
        'paused'  => $isPaused,
      ];
    }
    return $plan;
  }
}

if (!function_exists('bo_next_run')) {
  /* Next scheduled job, from the two cron times that actually exist:
     02:30 Duplicacy, 05:30 the Dropbox mirror. Hard-coded to match
     duplicacy.cron and rclone-dropbox.cron - if those move, this must too. */
  function bo_next_run() {
    $best = null; $what = '';
    foreach ([['02:30', 'Duplicacy'], ['05:30', 'Dropbox mirror']] as [$hhmm, $name]) {
      [$h, $m] = array_map('intval', explode(':', $hhmm));
      $t = mktime($h, $m, 0);
      if ($t <= time()) $t += 86400;
      if ($best === null || $t < $best) { $best = $t; $what = $name; }
    }
    return [$best, $what];
  }
}

if (!function_exists('bo_state')) {
  /* Gathers everything the panel needs into one array, so the renderer below
     contains layout only and the poll endpoint can reuse it verbatim. */
  function bo_state() {
    $inv  = bo_ini('/var/local/emhttp/backup-inventory.ini');
    $cov  = bo_ini('/var/local/emhttp/duplicacy-coverage.ini');
    $live = bo_ini('/var/local/emhttp/duplicacy.ini');
    $rc   = bo_ini('/var/local/emhttp/rclone-dropbox.ini');
    $rl   = bo_ini('/var/local/emhttp/rclone-dropbox-live.ini');
    $pg   = bo_ini('/var/local/emhttp/rclone-progress.ini');

    $get = function($a, $k, $d = '') { return isset($a[$k]) && trim((string)$a[$k]) !== '' ? trim((string)$a[$k]) : $d; };

    $plan = bo_plan();
    $rows = []; $gaps = []; $covered = 0; $slots = 0; $newest = null;

    foreach ($plan as $share => $spec) {
      $key   = 'cov_' . str_replace('-', '_', $share);
      $raw   = $get($cov, $key);
      $have  = [];
      foreach (explode('|', $raw) as $part) {
        if ($part === '') continue;
        $b = explode(':', $part, 2);
        $have[$b[0]] = isset($b[1]) ? $b[1] : '-';
      }

      $isPaused = !empty($spec['paused']);
      $cells = []; $ok = 0; $n = 0; $rowNewest = null;
      foreach (['g', 'd', 'm'] as $sk) {
        if ($isPaused) { $cells[$sk] = ['state' => 'paused']; continue; }
        if (!isset($spec['targets'][$sk])) { $cells[$sk] = ['state' => 'na']; continue; }
        $n++; $slots++;
        $tool = $spec['targets'][$sk];
        $v = $have[$sk] ?? null;

        if ($v === null) {
          $cells[$sk] = ['state' => 'unknown', 'tool' => $tool];
        } elseif (preg_match('/^seed([0-9.]+)$/', $v, $m)) {
          $cells[$sk] = ['state' => 'syncing', 'pct' => (float)$m[1], 'tool' => $tool];
        } elseif ($v === '-' || $v === '') {
          $cells[$sk] = ['state' => 'missing', 'tool' => $tool];
          $gaps[] = ['share' => $share, 'title' => $spec['title'], 'cloud' => $sk, 'tool' => $tool];
        } else {
          $rev = ''; $when = $v;
          if (preg_match('/^r([0-9]+)@(.*)$/', $v, $m)) { $rev = $m[1]; $when = $m[2]; }
          $ts = bo_parse_stamp($when);
          $cells[$sk] = ['state' => 'ok', 'ts' => $ts, 'rev' => $rev, 'tool' => $tool];
          $ok++; $covered++;
          if ($ts && (!$rowNewest || $ts > $rowNewest)) $rowNewest = $ts;
          if ($ts && (!$newest || $ts > $newest)) $newest = $ts;
        }
      }

      $ik = 'inv_' . str_replace('-', '_', $share);
      $rows[] = [
        'share' => $share, 'title' => $spec['title'], 'icon' => $spec['icon'], 'tint' => $spec['tint'],
        'cells' => $cells, 'ok' => $ok, 'targets' => $n,
        'paused' => $isPaused,
        'bytes' => (float)$get($inv, $ik . '_bytes', '0'),
        'files' => (int)$get($inv, $ik . '_files', '0'),
        'last'  => $rowNewest,
      ];
    }

    /* Current activity. Duplicacy takes precedence when both are moving, since
       its runs are short and the mirror runs for days. */
    $act = null;
    if ($get($live, 'status') === 'running' && $get($live, 'repo') !== '') {
      $act = [
        'what' => 'Backing up', 'target' => 'Google Drive', 'tool' => 'Duplicacy',
        'name' => $get($live, 'repo'),
        'pct'  => (float)str_replace('%', '', $get($live, 'pct', '0')),
        'rate' => $get($live, 'speed'), 'eta' => $get($live, 'eta'),
        'done' => '', 'total' => '',
      ];
    } elseif ($get($rc, 'rc_state') === 'running') {
      /* Prefer rc: it is instantaneous and reports the bytes of THIS run, which
         is what a progress bar should track. The cron files are the fallback for
         when rc is unreachable - a sync started before rc was enabled, or a
         wedged process. */
      $live  = bo_rc();
      $share = $live["share"] ?? $get($pg, "pg_share", $get($rc, "rc_share"));
      $t = bo_plan()[$share]["title"] ?? $share;
      if ($live) {
        $ov = bo_overall($share, $live);
        $act = [
          "what" => "Syncing", "target" => "Dropbox", "tool" => "rclone", "name" => $t,
          "pct"   => $ov["pct"],
          "rate"  => bo_rate($live["speed"]),
          "eta"   => bo_dur($live["eta"]),
          "done"  => bo_bytes($ov["done"]),
          "total" => bo_bytes($ov["total"]),
          'files' => $live['xfers'] ? number_format($live['xfers']) : '',
          'files_total' => '',
          'inflight' => $live['files'],
          'source' => 'rc',
        ];
      } else {
        $act = [
          'what' => 'Syncing', 'target' => 'Dropbox', 'tool' => 'rclone', 'name' => $t,
          'pct'  => (float)$get($pg, 'pg_pct', $get($rl, 'rl_pct', '0')),
          'rate' => bo_rate($get($pg, 'pg_rate', '0')),
          'eta'  => $get($pg, 'pg_eta'),
          'done' => bo_bytes($get($pg, 'pg_done', '0')),
          'total' => bo_bytes($get($pg, 'pg_total', '0')),
          'files' => $get($rl, 'rl_files'), 'files_total' => $get($rl, 'rl_total_files'),
          'inflight' => [], 'source' => 'cron',
        ];
      }
    }

    /* Anything mid-transfer is not a gap: a copy is actively being produced. */
    $syncing = 0;
    foreach ($rows as $r) foreach ($r['cells'] as $c) if (($c['state'] ?? '') === 'syncing') $syncing++;

    $pausedCount = 0;
    foreach ($rows as $r) if (!empty($r['paused'])) $pausedCount++;

    return [
      'rows' => $rows, 'gaps' => $gaps, 'act' => $act, 'syncing' => $syncing,
      'paused' => $pausedCount,
      'total_bytes' => (float)$get($inv, 'inv_total_bytes', '0'),
      'health' => $slots > 0 ? (int)round($covered * 100 / $slots) : 0,
      'covered' => $covered, 'slots' => $slots,
      'newest' => $newest,
      'inv_updated' => (int)$get($inv, 'inv_updated', '0'),
      'cov_updated' => $get($cov, 'cov_updated', 'never'),
      'rc_used' => $get($rc, 'rc_used'), 'rc_total' => $get($rc, 'rc_total'),
      'rl_errors' => (int)$get($rl, 'rl_errors', '0'),
    ];
  }
}

if (!function_exists('bo_overall')) {
  /* Overall share coverage, not just this run's progress.
   *
   * rc reports bytes/totalBytes for the CURRENT invocation: after a restart that
   * reads 0.5% even though half the share is already on Dropbox, which looks
   * like the transfer went backwards. rclone's totalBytes is what remains to be
   * sent, so everything already there is (local total - totalBytes), and the
   * honest progress figure is that plus what this run has moved.
   *
   * Falls back to run-local figures when the inventory has no entry for the
   * share - better a narrower truth than a confident wrong number.
   */
  function bo_overall($share, $rc) {
    $inv = bo_ini('/var/local/emhttp/backup-inventory.ini');
    $k   = 'inv_' . str_replace('-', '_', (string)$share) . '_bytes';
    $localTotal = isset($inv[$k]) ? (float)$inv[$k] : 0;

    if ($localTotal <= 0 || !$rc) {
      return ['done' => $rc['done'] ?? 0, 'total' => $rc['total'] ?? 0,
              'pct' => $rc['pct'] ?? 0, 'scope' => 'run'];
    }
    $already = $localTotal - (float)$rc['total'];
    if ($already < 0) $already = 0;
    $done = $already + (float)$rc['done'];
    if ($done > $localTotal) $done = $localTotal;
    return ['done' => $done, 'total' => $localTotal,
            'pct' => $localTotal > 0 ? $done * 100 / $localTotal : 0, 'scope' => 'share'];
  }
}

if (!function_exists('bo_inflight_text')) {
  /* One line naming what is actually moving. During a 1.5 TB seed "42%" alone is
     inert; seeing the filenames tick past is how you tell it is alive and what
     it is working through. */
  function bo_inflight_text($a) {
    if (!empty($a['inflight'])) {
      $names = [];
      foreach ($a['inflight'] as $f) {
        $n = $f['name'];
        if (strlen($n) > 34) $n = substr($n, 0, 31) . '...';
        $names[] = $n . ' ' . round($f['pct']) . '%';
      }
      return implode('   ', $names);
    }
    if (!empty($a['files']) && !empty($a['files_total'])) {
      return number_format((int)$a['files']) . ' / ' . number_format((int)$a['files_total']) . ' files';
    }
    if (!empty($a['files'])) return $a['files'] . ' files transferred this run';
    return '';
  }
}

if (!function_exists('bo_live_json')) {
  /* Small payload for the fast poll: only what changes second to second, so the
     1s tick costs a few hundred bytes instead of re-sending the whole panel. */
  function bo_live_json() {
    $rc   = bo_ini('/var/local/emhttp/rclone-dropbox.ini');
    $live = bo_ini('/var/local/emhttp/duplicacy.ini');
    $g = function($a, $k, $d = '') { return isset($a[$k]) && trim((string)$a[$k]) !== '' ? trim((string)$a[$k]) : $d; };

    $out = ['running' => false];

    if ($g($live, 'status') === 'running' && $g($live, 'repo') !== '') {
      $p = (float)str_replace('%', '', $g($live, 'pct', '0'));
      return ['running' => true, 'name' => $g($live, 'repo'), 'pct' => round($p, 1),
              'bytes' => '', 'rate' => $g($live, 'speed'), 'eta' => $g($live, 'eta'),
              'inflight' => 'Duplicacy to Google Drive'];
    }

    if ($g($rc, 'rc_state') === 'running') {
      $r = bo_rc();
      if ($r) {
        $share = $r['share'] ?: $g($rc, 'rc_share');
        /* Overall share progress, not this run's - see bo_overall. */
        $ov = bo_overall($share, $r);
        $out = [
          'running'  => true,
          'name'     => bo_plan()[$share]['title'] ?? $share,
          'pct'      => round($ov['pct'], 1),
          /* Whether the percentage label fits inside the filled bar is decided
             HERE, not in the tile's script. The script is emitted into a
             fragment that must parse as XML, and a JS comparison operator puts
             a literal angle bracket in it - which is exactly how this broke. */
          'inside'   => $ov['pct'] >= 14,
          'bytes'    => bo_bytes($ov['done']) . ' / ' . bo_bytes($ov['total']),
          'rate'     => bo_rate($r['speed']),
          'eta'      => bo_dur($r['eta']),
          'inflight' => bo_inflight_text(['inflight' => $r['files'], 'files' => $r['xfers']]),
          /* Single filename for the tile's "Uploading ..." line: during a
             multi-day seed the percentage barely moves minute to minute, but a
             filename turning over is unmistakable proof it is alive. */
          'file'     => (function($f) {
                          $n = $f[0]['name'] ?? '';
                          return strlen($n) > 30 ? substr($n, 0, 27) . '...' : $n;
                        })($r['files']),
          'errors'   => $r['errors'],
        ];
      } else {
        $out = ['running' => true, 'name' => $g($rc, 'rc_share'), 'pct' => 0,
                'bytes' => '', 'rate' => '', 'eta' => '', 'inflight' => 'rc unreachable'];
      }
    }
    return $out;
  }
}

if (!function_exists('bo_pal')) {
  /* One palette, shared by the tile and the page. The two surfaces having the
     same colours by coincidence is not the same as having them by construction. */
  function bo_pal() {
    return ['green' => '#16a34a', 'blue' => '#2563eb', 'amber' => '#b45309',
            'red'   => '#dc2626', 'grey'  => '#94a3b8', 'pale' => '#cbd5e1'];
  }
}

if (!function_exists('bo_mark')) {
  /* One family of dots, GitHub-Actions style. Defined here rather than in the
     widget so the page cannot drift from the tile: a green dot must mean the same
     thing in both places or neither can be trusted.

     The not-configured state took three attempts - an exclamation mark read as
     "broken", a hollow ring as "inactive", a dash as missing data. A greyed member
     of the same dot family reads as a state in the series, which is what it is. */
  function bo_mark($state, $px = 13) {
    $p = bo_pal();
    switch ($state) {
      case 'ok':
        return ['svg' => "<svg width='$px' height='$px' viewBox='0 0 12 12'><circle cx='6' cy='6' r='5' fill='{$p['green']}'/></svg>",
                'tip' => 'Backed up', 'word' => 'protected', 'colour' => $p['green']];
      case 'syncing':
        return ['svg' => bo_icon('sync', $px, $p['blue']),
                'tip' => 'Copy in progress', 'word' => 'uploading', 'colour' => $p['blue']];
      case 'missing':
        return ['svg' => "<svg width='$px' height='$px' viewBox='0 0 12 12'><circle cx='6' cy='6' r='5' fill='{$p['amber']}'/></svg>",
                'tip' => 'No backup copy yet - this target is configured but nothing has been uploaded to it',
                'word' => 'never backed up', 'colour' => $p['amber']];
      case 'unknown':
        return ['svg' => "<svg width='$px' height='$px' viewBox='0 0 12 12'><circle cx='6' cy='6' r='4.3' fill='none' stroke='{$p['grey']}' stroke-width='1.4' stroke-dasharray='2 2'/></svg>",
                'tip' => 'Not checked since boot', 'word' => 'not checked', 'colour' => $p['grey']];
      case 'paused':
        return ['svg' => "<svg width='$px' height='$px' viewBox='0 0 12 12'><circle cx='6' cy='6' r='5' fill='#64748b'/><rect x='4' y='3.3' width='1.3' height='5.4' rx='.4' fill='white'/><rect x='6.7' y='3.3' width='1.3' height='5.4' rx='.4' fill='white'/></svg>",
                'tip' => 'Cloud backup paused by policy', 'word' => 'paused', 'colour' => '#64748b'];
      default:
        return ['svg' => "<svg width='$px' height='$px' viewBox='0 0 12 12'><circle cx='6' cy='6' r='5' fill='{$p['pale']}'/></svg>",
                'tip' => 'Not configured - this dataset is not meant to go to this cloud',
                'word' => 'not configured', 'colour' => $p['grey']];
    }
  }
}

if (!function_exists('bo_row_state')) {
  /* A dataset's overall state, for the status dot in front of its name. Lets you
     spot the problem rows before reading any provider column. */
  function bo_row_state($r) {
    if (!empty($r['paused'])) return 'paused';
    if ($r['targets'] < 1) return 'na';
    $ok = 0; $half = 0; $miss = 0;
    foreach ($r['cells'] as $c) {
      $s = $c['state'] ?? 'na';
      if ($s === 'ok')      $ok++;
      if ($s === 'syncing') $half++;
      if ($s === 'missing') $miss++;
    }
    if ($ok === $r['targets']) return 'ok';
    if ($miss > 0 && $ok === 0 && $half === 0) return 'missing';
    if ($miss > 0) return 'missing';
    if ($half > 0) return 'syncing';
    return 'unknown';
  }
}

if (!function_exists('bo_render')) {
  /* Full-page overview.
   *
   * Deliberately NOT a row of KPI cards. Those read as a dashboard but earn
   * little: "5 datasets / 2 missing / 60% health" still leaves you looking at the
   * table to find out which two. The page has a whole screen, so it spends it on
   * the three facts worth stating outright, the transfer in its own section, and
   * then the datasets - with the same dots, colours, wording and provider order as
   * the tile.
   *
   * Timestamps are mostly gone from the surface. Healthy / uploading / missing is
   * what you want at a glance; the exact time matters only when something is
   * wrong, so it lives in the expansion and the tooltip.
   */
  function bo_render() {
    $st = bo_state();
    $q  = bo_score($st);
    $p  = bo_pal();
    $h  = function ($s) { return htmlspecialchars((string)$s, ENT_QUOTES); };

    $nMissing = count($st['gaps']);
    $scol = $q['pct'] >= 90 ? $p['green'] : ($q['pct'] >= 60 ? $p['amber'] : $p['red']);

    $cloudLabel = ['g' => 'Google', 'd' => 'Dropbox', 'm' => 'Mail.ru'];
    $cloudFull  = ['g' => 'Google Drive', 'd' => 'Dropbox', 'm' => 'mail.ru'];
    $cloudTool  = ['g' => 'Duplicacy', 'd' => 'rclone', 'm' => 'Duplicacy'];

    $out = "<div class='bo-wrap'>";

    /* ---- header ---- */
    /* With nothing configured there is no claim to make. "All protected" across
       zero datasets is the most misleading thing this page could say. */
    if (!$st['rows']) {
      $pill = "<span class='bo-pill' style='background:#94a3b81a;color:#64748b'>"
            . bo_icon('alert', 14, $p['grey']) . " Not configured</span>";
      $sub  = "Nothing is being monitored yet";
    } elseif ($nMissing > 0) {
      $pill = "<span class='bo-pill bo-pill-warn'>" . bo_icon('alert', 14, $p['amber'])
            . " $nMissing target" . ($nMissing > 1 ? 's' : '') . " missing</span>";
      $sub  = "Coverage across " . count($st['rows']) . " datasets";
    } else {
      $pill = "<span class='bo-pill bo-pill-ok'>" . bo_icon('check', 14, $p['green'])
            . " All protected</span>";
      $sub  = "Coverage across " . count($st['rows']) . " datasets";
    }

    $out .= "<div class='bo-head'>"
          . "<div class='bo-brandmark'>" . bo_icon('shield', 24, $p['blue']) . "</div>"
          . "<div class='bo-titles'><div class='bo-title'>Backup Overview</div>"
          . "<div class='bo-sub'>" . $sub . "</div></div>"
          . $pill
          . "<div class='bo-head-actions'><button type='button' class='bo-btn' onclick='boRefresh()'>"
          . bo_icon('refresh', 14, 'currentColor') . " Refresh</button></div></div>";

    /* ---- the three facts, and the score ---- */
    [$nextTs, $nextWhat] = bo_next_run();
    $facts = [
      ['icon' => 'check', 'colour' => $st['newest'] ? $p['green'] : $p['grey'],
       'label' => 'Last successful backup', 'value' => bo_when($st['newest'])],
      ['icon' => 'refresh', 'colour' => $p['grey'],
       'label' => 'Coverage last checked', 'value' => $h($st['cov_updated'])],
      ['icon' => 'clock', 'colour' => $p['grey'],
       'label' => 'Next scheduled run', 'value' => bo_when($nextTs) . " <span class='bo-dim'>" . $h($nextWhat) . "</span>"],
    ];

    $bits = [];
    if ($q['full'])    $bits[] = "<span style='color:{$p['green']}'>{$q['full']} full</span>";
    if ($q['syncing']) $bits[] = "<span style='color:{$p['green']}'>{$q['syncing']} syncing</span>";
    if ($q['partial']) $bits[] = "<span style='color:{$p['amber']}'>{$q['partial']} partial</span>";
    if ($q['none'])    $bits[] = "<span style='color:{$p['red']}'>{$q['none']} none</span>";

    /* Same reasoning as the tile: no configuration is a distinct state, and a page
       full of zeroes claims to have measured something. */
    if (!$st['rows']) {
      $out .= "<div class='bo-empty'>" . bo_icon('shield', 26, $p['grey'])
            . "<div><div class='bo-empty-h'>No datasets configured yet</div>"
            . "<div class='bo-empty-t'>Pick the shares to watch, and which clouds each one is "
            . "meant to reach. Nothing is monitored until you do - this page reports on "
            . "Duplicacy and rclone, it does not set them up.</div>"
            . "<a class='bo-btn' href='/Utilities/BackupWidget'>Open settings &#8594;</a>"
            . "</div></div></div>";
      return $out;
    }

    $out .= "<div class='bo-summary'><div class='bo-facts'>";
    foreach ($facts as $f) {
      $out .= "<div class='bo-fact'>" . bo_icon($f['icon'], 15, $f['colour'])
            . "<span class='bo-fact-l'>" . $f['label'] . "</span>"
            . "<span class='bo-fact-v'>" . $f['value'] . "</span></div>";
    }
    $out .= "</div><div class='bo-scorebox'>"
          . "<div class='bo-score-l'>Protection score</div>"
          . "<div class='bo-score-row'>"
          . "<div class='bo-score-bar'><i style='width:{$q['pct']}%;background:$scol'></i></div>"
          . "<div class='bo-score-n' style='color:$scol'>{$q['pct']}%</div></div>"
          . "<div class='bo-score-b'>" . implode(" &#183; ", $bits) . "</div>"
          . "</div></div>";


    /* ---- provider capacity ---- */
    /* The one question the coverage table cannot answer - not "is there a copy"
       but "is there room for the next one". A provider filling up degrades
       silently: the backup that fails is the one after the last successful run.
       Used is drawn from free rather than from the reported used figure. On Google
       Drive these disagree by more than a terabyte, because Google Photos and
       Family sharing consume the same quota and arrive as "other". Free is the
       number that decides whether tonight's run fits. */
    $qt = bo_quota();
    $out .= "<div class='bo-quota'>"
          . "<div class='bo-quota-h'>" . bo_icon('files', 15, $p['grey'])
          . " Provider capacity <span class='bo-dim'>"
          . ($qt['updated'] !== '' ? "measured " . $h($qt['updated']) : "not measured yet")
          . "</span></div><div class='bo-quota-g'>";
    foreach (['g', 'd', 'm'] as $sk) {
      $x   = $qt[$sk] ?? null;
      $col = bo_quota_colour($x);
      $out .= "<div class='bo-qc'>"
            . "<div class='bo-qc-h'>" . bo_brand($sk, 16)
            . "<span class='bo-qc-n'>" . $h($cloudFull[$sk]) . "</span>"
            . "<span class='bo-tool2'>" . $h($cloudTool[$sk]) . "</span></div>";
      if (!$x) {
        /* Absent figures are stated. Drawing an empty bar would read as a full
           provider and send the operator chasing a problem that is not there. */
        $out .= "<div class='bo-qc-v' style='color:{$p['grey']}'>no figures</div>"
              . "<div class='bo-qc-bar'></div>"
              . "<div class='bo-qc-s'>The last check could not read this provider's quota</div>";
      } else {
        $note = $x['pct'] . "% used";
        if ($x['other'] > 0) {
          $note .= " &#183; " . bo_bytes($x['other']) . " of it is other data sharing this quota";
        }
        if ($x['stale']) {
          $note .= " &#183; <span style='color:{$p['amber']}'>last check failed, figures from "
                 . ($x['at'] > 0 ? bo_ago($x['at']) : 'an earlier run') . "</span>";
        }
        $out .= "<div class='bo-qc-v'><b style='color:$col'>" . bo_bytes($x['free'])
              . "</b> free <span class='bo-dim'>of " . bo_bytes($x['total']) . "</span></div>"
              . "<div class='bo-qc-bar'><i style='width:{$x['pct']}%;background:$col'></i></div>"
              . "<div class='bo-qc-s'>" . $note . "</div>";
      }
      $out .= "</div>";
    }
    $out .= "</div></div>";

    /* ---- current transfer, its own section ---- */
    if ($st['act']) {
      $a   = $st['act'];
      $pct = max(0, min(100, $a['pct']));
      $file = '';
      if (!empty($a['inflight']) && is_array($a['inflight'])) {
        $file = $a['inflight'][0]['name'] ?? '';
      }
      $out .= "<div class='bo-act' id='bo-act'>"
            . "<div class='bo-act-head'>"
            . "<span class='bo-spin'>" . bo_icon('sync', 17, $p['blue']) . "</span>"
            . "<b>Currently transferring</b>"
            . "<span class='bo-act-what'><b id='bo-act-name'>" . $h($a['name']) . "</b> &#8594; "
            . $h($a['target']) . " <span class='bo-dim'>" . $h($a['tool']) . "</span></span>"
            . "</div>"
            . "<div class='bo-act-file' id='bo-file'>" . $h($file) . "</div>"
            . "<div class='bo-bar'><div class='bo-bar-fill' id='bo-bar' style='width:{$pct}%'></div>"
            . "<div class='bo-bar-lbl' id='bo-pct'>" . round($pct) . "%</div></div>"
            . "<div class='bo-act-stats'>"
            . "<span>" . bo_icon('files', 15, $p['grey']) . " <span id='bo-bytes'>"
            . $h(trim($a['done'] . ' / ' . $a['total'], ' /')) . "</span></span>"
            . "<span>" . bo_icon('pulse', 15, $p['green']) . " <span id='bo-rate'>" . $h($a['rate']) . "</span></span>"
            . "<span>" . bo_icon('clock', 15, $p['grey']) . " ETA <span id='bo-eta'>"
            . $h($a['eta'] !== '' ? $a['eta'] : '?') . "</span></span>"
            . "</div></div>";
    }

    /* ---- datasets ---- */
    $out .= "<div class='bo-table-scroll'><div class='bo-table'>";
    $out .= "<div class='bo-tr bo-th'><div>Dataset</div>";
    foreach (['g', 'd', 'm'] as $sk) {
      $out .= "<div><span class='bo-hcol'>" . bo_brand($sk, 15)
            . "<span>" . $cloudLabel[$sk] . "</span></span>"
            . "<span class='bo-tool2'>" . $cloudTool[$sk] . "</span></div>";
    }
    $out .= "<div><span class='bo-hcol'><span>History</span></span>"
          . "<span class='bo-tool2'>last 5 checks</span></div>"
          . "<div></div></div>";

    foreach ($st['rows'] as $r) {
      $rs  = bo_row_state($r);
      $rm  = bo_mark($rs, 12);
      $did = 'bo-d-' . preg_replace('/[^a-z0-9]+/i', '-', $r['share']);

      $out .= "<div class='bo-tr bo-row' onclick=\"boToggle('$did')\">";
      $out .= "<div class='bo-ds'>"
            . "<span title='" . $h(ucfirst($rm['word'])) . "'>" . $rm['svg'] . "</span>"
            . "<span class='bo-ds-ico' style='background:" . $r['tint'] . "1a'>"
            . bo_icon($r['icon'], 15, $r['tint']) . "</span>"
            . "<span class='bo-dsn'><b>" . $h($r['title'])
            . (!empty($r['paused']) ? " <span class='bo-pause'>Paused</span>" : "") . "</b>"
            . "<span class='bo-dssz'>" . bo_bytes($r['bytes']) . "</span></span></div>";

      foreach (['g', 'd', 'm'] as $sk) {
        $c = $r['cells'][$sk];
        $state = $c['state'] ?? 'na';
        $m = bo_mark($state, 13);

        /* State in words, not a timestamp. The exact time only matters when
           something is wrong, and then it is one click or one hover away. */
        $word = $m['word'];
        if ($state === 'syncing') $word = 'uploading ' . round($c['pct']) . '%';

        $tip = $cloudFull[$sk] . " - " . $cloudTool[$sk] . "\n";
        if ($state === 'ok') {
          $tip .= "Last backup: " . strip_tags(bo_when($c['ts']));
          if (($c['rev'] ?? '') !== '') $tip .= " (revision {$c['rev']})";
        } elseif ($state === 'syncing') {
          $tip .= "Uploading now: " . round($c['pct']) . "% of bytes present";
        } elseif ($state === 'missing') {
          $tip .= "Never backed up\nTarget is configured but has received nothing yet";
        } else {
          $tip .= $m['tip'];
        }
        $tip .= "\nSource: /mnt/user/" . $r['share'];

        $out .= "<div class='bo-cell' title='" . $h($tip) . "'>" . $m['svg']
              . " <span style='color:" . $m['colour'] . "'>" . $h($word) . "</span></div>";
      }

      $out .= "<div class='bo-cell'>" . (!empty($r['paused'])
            ? "<span class='bo-paused-history'>paused</span>"
            : bo_sparkline($r['share'], 15, 5)) . "</div>";
      $out .= "<div class='bo-chev'>" . bo_icon('chev', 14, $p['grey']) . "</div>";
      $out .= "</div>";

      /* expansion: the per-cloud story, same shape as the tile */
      $out .= "<div class='bo-det' id='$did'>";
      foreach (['g', 'd', 'm'] as $sk) {
        if (!isset($r['cells'][$sk])) continue;
        $c = $r['cells'][$sk];
        $state = $c['state'] ?? 'na';
        $m = bo_mark($state, 12);

        if ($state === 'ok') {
          $detail = bo_when($c['ts']) . (($c['rev'] ?? '') !== '' ? " <span class='bo-dim'>revision {$c['rev']}</span>" : '');
        } elseif ($state === 'syncing') {
          $detail = "uploading, " . round($c['pct']) . "% of bytes present";
        } elseif ($state === 'missing') {
          $detail = "never backed up";
        } else {
          $detail = $m['word'];
        }

        $out .= "<div class='bo-detr'>"
              . "<span class='bo-detc'>" . $m['svg'] . " " . $h($cloudFull[$sk])
              . " <span class='bo-dim'>" . $h($cloudTool[$sk]) . "</span></span>"
              . "<span class='bo-dets' style='color:" . $m['colour'] . "'>" . $detail . "</span></div>";
      }
      $out .= "<div class='bo-detr bo-detp'>"
            . "<span class='bo-detc'>/mnt/user/" . $h($r['share']) . "</span>"
            . "<span class='bo-dets'>" . number_format($r['files']) . " files &#183; "
            . bo_bytes($r['bytes']) . "</span></div>";
      $out .= "</div>";
    }
    $out .= "</div></div>";

    /* ---- attention, as a task list ---- */
    $tasks = [];
    foreach ($st['gaps'] as $g) {
      /* The Duplicacy command is derivable from the config, so it is real on any
         host. The mirror command is NOT - it is whatever sync script the operator
         wrote - so it is only offered when they have told us its path. Printing
         this author's own script path to a stranger would be an instruction to run
         a file that does not exist on their machine. */
      $map = bo_storage_map();
      if ($g['tool'] === 'rclone') {
        $cmd = bo_conf('BW_SYNC_CMD', '');
      } else {
        $storage = $g['cloud'] === 'm' ? ($map['m'][0] ?? 'mailru') : ($map['g'][0] ?? 'gdrive');
        $cmd = 'cd ' . escapeshellarg('/mnt/user/' . $g['share'])
             . ' && ' . escapeshellarg(bo_dup_dir() . '/bin/duplicacy')
             . ' backup -storage ' . escapeshellarg($storage);
      }
      $tasks[] = [
        'title' => $g['title'] ?? $g['share'],
        'what'  => "No copy on " . $cloudFull[$g['cloud']],
        'why'   => "The target is configured. Nothing has been uploaded to it yet.",
        'cmd'   => $cmd,
      ];
    }
    foreach ($st['rows'] as $r) {
      if ($r['targets'] === 1) {
        $tasks[] = [
          'title' => $r['title'],
          'what'  => "Only one cloud target configured",
          'why'   => "A single copy off-site means one provider problem is a total loss.",
          'cmd'   => '',
        ];
      }
    }
    /* A provider nearly full belongs in the attention list, not only in a bar.
       Under 15% free the next large dataset may not fit, and the failure arrives
       as a backup that silently did not happen. */
    foreach (['g' => 'Google Drive', 'd' => 'Dropbox', 'm' => 'mail.ru'] as $sk => $name) {
      $x = bo_quota()[$sk] ?? null;
      if (!$x || $x['total'] <= 0) continue;
      $frac = $x['free'] / $x['total'];
      if ($frac >= 0.15) continue;
      $tasks[] = [
        'title' => $name,
        'what'  => bo_bytes($x['free']) . " free of " . bo_bytes($x['total'])
                 . " (" . $x['pct'] . "% used)",
        'why'   => $frac < 0.05
                   ? "Almost full. The next run is likely to fail part-way, which leaves an incomplete copy rather than an obvious error."
                   : "Running low. Free space or raise the plan before the next large dataset needs it.",
        'cmd'   => '',
      ];
    }
    if ($st['rl_errors'] > 0) {
      $tasks[] = [
        'title' => 'Dropbox mirror',
        'what'  => $st['rl_errors'] . " error" . ($st['rl_errors'] > 1 ? 's' : '') . " in today's sync log",
        'why'   => "Individual files failed to transfer; the run itself continued.",
        'cmd'   => 'tail -50 ' . escapeshellarg(bo_rclone_dir() . '/logs/dropbox-sync-' . date('Y-m-d') . '.log'),
      ];
    }

    if ($tasks) {
      $out .= "<div class='bo-attn'><div class='bo-attn-h'>" . bo_icon('alert', 16, $p['amber'])
            . " Needs attention <span class='bo-dim'>" . count($tasks) . " item"
            . (count($tasks) > 1 ? 's' : '') . "</span></div>";
      foreach ($tasks as $t) {
        $out .= "<div class='bo-task'>"
              . "<div class='bo-task-b'>" . bo_icon('alert', 14, $p['amber']) . "</div>"
              . "<div class='bo-task-t'><div class='bo-task-h'>" . $t['title']
              . " <span class='bo-dim'>&#183; " . $t['what'] . "</span></div>"
              . "<div class='bo-task-w'>" . $t['why'] . "</div>"
              /* The command, not a button. A web endpoint that runs backups as
                 root is a security surface this deliberately does not have, so the
                 page hands you the exact thing to run instead of pretending. */
              . ($t['cmd'] !== '' ? "<code class='bo-task-c'>" . $h($t['cmd']) . "</code>" : "")
              . "</div></div>";
      }
      $out .= "</div>";
    } else {
      $out .= "<div class='bo-allok'>" . bo_icon('check', 17, $p['green'])
            . " Every configured target holds a copy</div>";
    }

    $out .= "<div class='bo-foot'><span>Live figures from rclone; coverage from the 6-hourly check"
          . "</span><span>refreshing in <b id='bo-count'>30</b>s</span></div>";

    return $out . "</div>";
  }
}

if (!function_exists('bo_score')) {
  /* Backup score, and the per-dataset breakdown behind it.
   *
   * The first version scored "datasets where every target holds a copy", which
   * read 40% for an estate in decent shape: two datasets perfect, two missing
   * only their optional third copy, one mid-upload. 40% says "almost everything
   * is broken", and that was not what was happening. A metric that overstates
   * danger gets ignored exactly like one that understates it.
   *
   * Scored per dataset and averaged, so a dataset with three targets is not
   * punished three times for one absence, and an upload in progress earns half
   * credit because a copy is actively being produced.
   */
  function bo_score($st) {
    $full = 0; $partial = 0; $syncing = 0; $none = 0; $sum = 0.0; $n = 0;

    foreach ($st['rows'] as $r) {
      if ($r['targets'] < 1) continue;
      $n++;
      $ok = 0; $half = 0;
      foreach ($r['cells'] as $c) {
        $s = $c['state'] ?? 'na';
        if ($s === 'ok')      $ok++;
        if ($s === 'syncing') $half++;
      }
      $sum += ($ok + 0.5 * $half) / $r['targets'];

      if ($ok === $r['targets'])  $full++;
      elseif ($half > 0)          $syncing++;
      elseif ($ok > 0)            $partial++;
      else                        $none++;
    }

    return ['pct' => $n > 0 ? (int)round($sum * 100 / $n) : 0, 'full' => $full,
            'partial' => $partial, 'syncing' => $syncing, 'none' => $none, 'total' => $n];
  }
}

if (!function_exists('bo_history_path')) {
  function bo_history_path() { return '/boot/config/plugins/backup-widget/history.tsv'; }
}

if (!function_exists('bo_record_history')) {
  /* Append one sample per dataset. Called by the 6-hourly collector.
   *
   * On flash, because history that resets at every reboot is not history. Four
   * writes a day of a few hundred bytes is nothing against flash wear, and the
   * file is trimmed so it cannot grow without bound.
   *
   * Answers a question no snapshot can: is this dataset reliably healthy, or
   * does it fail every other run?
   */
  function bo_record_history() {
    $st = bo_state();
    $p  = bo_history_path();
    if (!is_dir(dirname($p))) return false;

    $now = time();
    $lines = [];
    foreach ($st['rows'] as $r) {
      if ($r['targets'] < 1) continue;
      $ok = 0; $half = 0;
      foreach ($r['cells'] as $c) {
        $s = $c['state'] ?? 'na';
        if ($s === 'ok')      $ok++;
        if ($s === 'syncing') $half++;
      }
      $state = ($ok === $r['targets']) ? 'full'
             : ($half > 0 ? 'syncing' : ($ok > 0 ? 'partial' : 'none'));
      $lines[] = "$now\t{$r['share']}\t$state";
    }
    if (!$lines) return false;

    file_put_contents($p, implode("\n", $lines) . "\n", FILE_APPEND | LOCK_EX);
    @chmod($p, 0600);

    /* Keep the tail only: 40 samples per dataset is ample for a sparkline and
       bounds the file at a few KB. */
    $all = @file($p, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    $cap = 40 * max(1, count($lines));
    if (count($all) > $cap) {
      file_put_contents($p, implode("\n", array_slice($all, -$cap)) . "\n", LOCK_EX);
    }
    return true;
  }
}

if (!function_exists('bo_history')) {
  /* Last $keep samples per dataset, oldest first. */
  function bo_history($keep = 14) {
    static $cache = null;
    if ($cache !== null) return $cache;
    $cache = [];
    foreach (@file(bo_history_path(), FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $l) {
      $p = explode("\t", $l);
      if (count($p) < 3) continue;
      $cache[$p[1]][] = ['ts' => (int)$p[0], 'state' => $p[2]];
    }
    foreach ($cache as $k => $v) $cache[$k] = array_slice($v, -$keep);
    return $cache;
  }
}

if (!function_exists('bo_sparkline')) {
  /* Compact run history. Bars rather than glyphs: a row of bars is legible at
     3px wide where a row of ticks and crosses is not. Bar HEIGHT also encodes
     state, so it survives monochrome and colour-blind readers. */
  function bo_sparkline($share, $h = 14, $keep = 5) {
    $rows = bo_history($keep)[$share] ?? [];
    if (!$rows) {
      return "<span class='bw-spk-none' title='No history yet - samples are recorded"
           . " by the 6-hourly coverage check, so this fills in over about four days'>"
           . "&#183;&#183;&#183;</span>";
    }

    /* Syncing is blue HERE but green in the score breakdown, and that is
       deliberate. In the breakdown it answers "is this healthy" - a copy being
       produced is healthy. In history it answers "what was the state at that
       sample" - and mid-transfer is genuinely a different state from complete,
       which is the distinction the sparkline exists to show. */
    $col = ['full' => '#16a34a', 'partial' => '#b45309', 'syncing' => '#2563eb', 'none' => '#dc2626'];
    /* Five wide bars rather than fourteen hairlines. At 3px the row read as a
       single tick and nobody could tell what it was; at 6px it reads as a
       sequence, which is the whole point. */
    $w = 6; $gap = 2.4;
    $tot = round(count($rows) * ($w + $gap));
    $svg = "<svg width='$tot' height='$h' viewBox='0 0 $tot $h' role='img'"
         . " aria-label='Recent backup history'>";
    $x = 0;
    foreach ($rows as $r) {
      $c  = $col[$r['state']] ?? '#94a3b8';
      $bh = $r['state'] === 'full' ? $h : ($r['state'] === 'syncing' ? (int)round($h * .66) : (int)round($h * .45));
      $svg .= "<rect x='" . round($x, 1) . "' y='" . ($h - $bh) . "' width='$w' height='$bh' rx='1' fill='$c'/>";
      $x += $w + $gap;
    }
    $svg .= "</svg>";

    $last = end($rows);
    $tip = count($rows) . " samples, newest " . date('d/m H:i', $last['ts']) . " (" . $last['state'] . ")";
    return "<span title='" . htmlspecialchars($tip, ENT_QUOTES) . "'>$svg</span>";
  }
}

?>
