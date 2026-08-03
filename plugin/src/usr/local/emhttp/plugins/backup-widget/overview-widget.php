<?PHP
/* Compact renderer for the Unraid dashboard tile.
 *
 * Reuses bo_state() from overview.php, so the tile and the full page can never
 * disagree - a widget claiming "protected" while the page shows a missing backup
 * is worse than no widget at all. Only the layout differs: a dashboard tile is
 * about 330px wide, so the seven-column table becomes one line per dataset with
 * three status marks, and the five stat cards collapse into a gauge and a line.
 *
 * Wording rules, from review:
 *   - "backup targets missing", never "gaps". Gap is our jargon.
 *   - Lead with "Attention required" when something needs doing, so the state is
 *     named before the count.
 *   - Score per dataset, averaged, half credit for uploads in progress. Counting
 *     "datasets where every target is present" read 40% for an estate that was
 *     genuinely fine, and a metric that overstates danger gets ignored just like
 *     one that understates it. See bo_score().
 *
 * Status marks are shape and colour, not glyph soup:
 *   filled green dot   a copy exists
 *   blue sync arrows   a copy is being made right now
 *   filled amber dot   configured target with no copy yet
 *   grey dash          not a target by design
 * A hollow ring was tried for the last case and read as "inactive" rather than
 * "not applicable"; a dash says nothing-to-see-here without implying a state.
 * An exclamation mark was tried for the amber case and read as "broken".
 *
 * Element ids are prefixed bw- and are distinct from the page's bo- ids: both can
 * be open in one browser at once, and a shared id would have the tile's 1s tick
 * writing into the page's DOM.
 */
require_once '/usr/local/emhttp/plugins/backup-widget/overview.php';

if (!function_exists('bw_mark')) {
  function bw_mark($state, $green, $amber, $blue, $grey) {
    switch ($state) {
      case 'ok':
        return ['svg' => "<svg width='11' height='11' viewBox='0 0 12 12'><circle cx='6' cy='6' r='5' fill='$green'/></svg>",
                'tip' => 'Backed up'];
      case 'syncing':
        return ['svg' => bo_icon('sync', 12, $blue), 'tip' => 'Copy in progress'];
      case 'missing':
        return ['svg' => "<svg width='11' height='11' viewBox='0 0 12 12'><circle cx='6' cy='6' r='5' fill='$amber'/></svg>",
                'tip' => 'No backup copy yet - this target is configured but nothing has been uploaded to it'];
      case 'unknown':
        return ['svg' => "<svg width='11' height='11' viewBox='0 0 12 12'><circle cx='6' cy='6' r='4.3' fill='none' stroke='$grey' stroke-width='1.4' stroke-dasharray='2 2'/></svg>",
                'tip' => 'Not checked since boot'];
      default:
        return ['svg' => "<svg width='11' height='11' viewBox='0 0 12 12'><rect x='1.5' y='5.2' width='9' height='1.6' rx='.8' fill='$grey'/></svg>",
                'tip' => 'Not configured - this dataset is not meant to go to this cloud'];
    }
  }
}

if (!function_exists('bw_gauge')) {
  /* Ring gauge. Larger and thinner than the first attempt: at stroke 3.4 a red or
     amber ring dominated a tile it only needs to lead. pathLength=100 lets the
     dash array be the percentage directly, with no circumference arithmetic. */
  function bw_gauge($pct, $colour, $px = 61) {
    $pct = max(0, min(100, (int)$pct));
    return "<svg width='$px' height='$px' viewBox='0 0 36 36' role='img'"
         . " aria-label='Backup score $pct percent'>"
         . "<circle cx='18' cy='18' r='16' fill='none' stroke='#e2e8f0' stroke-width='2.2'/>"
         . "<circle cx='18' cy='18' r='16' fill='none' stroke='$colour' stroke-width='2.2'"
         . " stroke-linecap='round' pathLength='100' stroke-dasharray='$pct 100'"
         . " transform='rotate(-90 18 18)'/>"
         . "<text x='18' y='20.6' text-anchor='middle' font-size='9.5' font-weight='700'"
         . " fill='$colour'>$pct%</text></svg>";
  }
}

if (!function_exists('bo_render_widget')) {
  function bo_render_widget() {
    $st = bo_state();
    $h  = function ($s) { return htmlspecialchars((string)$s, ENT_QUOTES); };

    $green = '#16a34a'; $red = '#dc2626'; $amber = '#d97706';
    $blue  = '#2563eb'; $grey = '#94a3b8';

    $q        = bo_score($st);
    $nMissing = count($st['gaps']);
    $gcol     = $q['pct'] >= 90 ? $green : ($q['pct'] >= 60 ? $amber : $red);

    $out = "<div class='bw'>";

    /* ---- gauge, headline, breakdown ---- */
    if ($nMissing > 0) {
      $line1 = "<span style='color:$amber;font-weight:700'>Attention required</span>";
      $line2 = "$nMissing backup target" . ($nMissing > 1 ? 's' : '') . " missing";
    } elseif ($st['syncing'] > 0) {
      $line1 = "<span style='color:$blue;font-weight:700'>Copies in progress</span>";
      $line2 = $st['syncing'] . " upload" . ($st['syncing'] > 1 ? 's' : '') . " running";
    } else {
      $line1 = "<span style='color:$green;font-weight:700'>Fully protected</span>";
      $line2 = "every configured target holds a copy";
    }

    /* Breakdown in words, because a single percentage hides which datasets are
       actually short. */
    $bits = [];
    if ($q['full'])    $bits[] = "<span style='color:$green'>{$q['full']} full</span>";
    if ($q['syncing']) $bits[] = "<span style='color:$blue'>{$q['syncing']} syncing</span>";
    if ($q['partial']) $bits[] = "<span style='color:$amber'>{$q['partial']} partial</span>";
    if ($q['none'])    $bits[] = "<span style='color:$red'>{$q['none']} none</span>";

    $out .= "<div class='bw-head'>"
          . "<div class='bw-gauge'>" . bw_gauge($q['pct'], $gcol)
          . "<div class='bw-gauge-l'>Backup score</div></div>"
          . "<div class='bw-headtxt'>"
          . "<div class='bw-headline'>$line1</div>"
          . "<div class='bw-sub'>$line2</div>"
          . "<div class='bw-sub bw-break'>" . implode(" &#183; ", $bits) . "</div>"
          . "</div></div>";

    /* ---- live transfer ---- */
    if ($st['act']) {
      $a   = $st['act'];
      $pct = max(0, min(100, $a['pct']));
      $inside = $pct >= 14;

      /* Name the file being moved. During a multi-day seed a percentage barely
         changes minute to minute, but the filename turning over is unmistakable
         proof it is alive - and it tells you what it is working through. */
      $file = '';
      if (!empty($a['inflight']) && is_array($a['inflight'])) {
        $first = $a['inflight'][0]['name'] ?? '';
        if ($first !== '') $file = strlen($first) > 30 ? substr($first, 0, 27) . '...' : $first;
      }

      $out .= "<div class='bw-act'>"
            . "<div class='bw-act-l'><b id='bw-name'>" . $h($a['name']) . "</b> "
            . "&#8594; " . $h($a['target'])
            . " <span class='bw-tool'>" . $h($a['tool']) . "</span></div>"
            . "<div class='bw-file'>Uploading <span id='bw-file'>" . $h($file) . "</span></div>"
            . "<div class='bw-bar'>"
            . "<div class='bw-bar-f' id='bw-bar' style='width:{$pct}%'>"
            . "<span class='bw-pct-in' id='bw-pct'>" . ($inside ? round($pct) . '%' : '') . "</span>"
            . "</div>"
            . "<span class='bw-pct-out' id='bw-pct-out'>" . ($inside ? '' : round($pct) . '%') . "</span>"
            . "</div>"
            . "<div class='bw-act-s'>"
            . "<span id='bw-bytes'>" . $h(trim($a['done'] . ' / ' . $a['total'], ' /')) . "</span>"
            . "<span id='bw-rate'>" . $h($a['rate']) . "</span>"
            . "<span>ETA <span id='bw-eta'>" . $h($a['eta'] !== '' ? $a['eta'] : '?') . "</span></span>"
            . "</div></div>";
    } else {
      $out .= "<div class='bw-idle'>No transfer running</div>";
    }

    /* ---- per-dataset grid ---- */
    $cloudLabel = ['g' => 'Google', 'd' => 'Dropbox', 'm' => 'Mail.ru'];
    $cloudFull  = ['g' => 'Google Drive', 'd' => 'Dropbox', 'm' => 'mail.ru'];
    $cloudTool  = ['g' => 'Duplicacy', 'd' => 'rclone', 'm' => 'Duplicacy'];

    $out .= "<div class='bw-grid'>";
    $out .= "<div class='bw-gr bw-gh'><span></span>";
    foreach (['g', 'd', 'm'] as $sk) {
      $out .= "<span class='bw-mk' title='" . $h($cloudFull[$sk] . ' via ' . $cloudTool[$sk]) . "'>"
            . bo_brand($sk, 12) . "<span class='bw-cl'>" . $h($cloudLabel[$sk]) . "</span></span>";
    }
    $out .= "<span class='bw-spk-h' title='State at each of the last 14 coverage checks'>history</span></div>";

    foreach ($st['rows'] as $r) {
      $did = 'bw-d-' . preg_replace('/[^a-z0-9]+/i', '-', $r['share']);
      $out .= "<div class='bw-gr bw-row' onclick=\"bwToggle('$did')\" title='Click for detail'>"
            . "<span class='bw-ds'>" . bo_icon($r['icon'], 13, $r['tint'])
            . "<span class='bw-dsn'>" . $h($r['title']) . "</span></span>";
      foreach (['g', 'd', 'm'] as $sk) {
        $c = $r['cells'][$sk];
        $m = bw_mark($c['state'] ?? 'na', $green, $amber, $blue, $grey);
        $tip = $m['tip'];
        if (($c['state'] ?? '') === 'ok')      $tip .= ' - ' . bo_when($c['ts']);
        if (($c['state'] ?? '') === 'syncing') $tip .= ' - ' . round($c['pct']) . '% of bytes uploaded';
        $out .= "<span class='bw-mk' title='" . $h($tip) . "'>" . $m['svg'] . "</span>";
      }
      $out .= "<span class='bw-spk'>" . bo_sparkline($r['share']) . "</span>";
      $out .= "</div>";

      /* Collapsed detail. One row per cloud, cloud on the left and its state on
         the right of the SAME line - the earlier version split these into two
         stacked blocks, so reading "when was Dropbox last done" meant crossing
         between two columns and counting positions. */
      $out .= "<div class='bw-det' id='$did'>";
      foreach (['g', 'd', 'm'] as $sk) {
        if (!isset($r['cells'][$sk])) continue;
        $c = $r['cells'][$sk];
        $state = $c['state'] ?? 'na';
        $m = bw_mark($state, $green, $amber, $blue, $grey);

        if ($state === 'na') {
          $txt = "<span style='color:$grey'>not configured</span>";
        } elseif ($state === 'ok') {
          $txt = "<span style='color:$green'>" . bo_when($c['ts'])
               . (($c['rev'] ?? '') !== '' ? " <span class='bw-rev'>rev " . $h($c['rev']) . "</span>" : '') . "</span>";
        } elseif ($state === 'syncing') {
          $txt = "<span style='color:$blue'>uploading " . round($c['pct']) . "%</span>";
        } elseif ($state === 'unknown') {
          $txt = "<span style='color:$grey'>not checked yet</span>";
        } else {
          $txt = "<span style='color:$amber'>never backed up</span>";
        }

        $out .= "<div class='bw-detr'>"
              . "<span class='bw-detc'>" . $h($cloudFull[$sk])
              . " <span class='bw-tool'>" . $h($cloudTool[$sk]) . "</span></span>"
              . "<span class='bw-dets'>" . $m['svg'] . " $txt</span>"
              . "</div>";
      }
      $out .= "<div class='bw-detr bw-detp'>"
            . "<span class='bw-detc'>/mnt/user/" . $h($r['share']) . "</span>"
            . "<span class='bw-dets'>" . number_format($r['files']) . " files &#183; "
            . bo_bytes($r['bytes']) . "</span></div>";
      $out .= "</div>";
    }
    $out .= "</div>";

    [$nextTs, $nextWhat] = bo_next_run();
    $out .= "<div class='bw-foot'>next " . $h(date('H:i', $nextTs)) . " " . $h($nextWhat)
          . " &#183; checked " . $h($st['cov_updated']) . "</div>";

    return $out . "</div>";
  }
}

if (!function_exists('bo_widget_header')) {
  function bo_widget_header() {
    $st = bo_state();
    $running = (bool)$st['act'];
    $missing = count($st['gaps']);
    $colour  = $running ? '#2563eb' : ($missing ? '#d97706' : '#16a34a');
    $label   = $running ? 'transferring' : ($missing ? 'action needed' : 'protected');
    return "<span style='color:$colour'>&#9679;</span> "
         . "<span style='font-weight:normal;opacity:.7'>$label</span>";
  }
}
?>
