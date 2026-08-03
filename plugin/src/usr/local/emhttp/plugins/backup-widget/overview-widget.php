<?PHP
/* Compact renderer for the Unraid dashboard tile.
 *
 * Reuses bo_state() from overview.php, so the tile and the full page can never
 * disagree - a widget claiming "protected" while the page shows a missing backup
 * is worse than no widget at all. Only the layout differs: a dashboard tile is
 * about 330px wide, so the seven-column table becomes one line per dataset with
 * three status marks, and the five stat cards collapse into a gauge plus a line.
 *
 * Wording rules, from review:
 *   - "missing backups", never "gaps". Gap is our jargon, not a fact about the
 *     system; the reader wants to know a backup is absent.
 *   - Count DATASETS fully protected, not individual cloud copies. "6 of 10
 *     copies" needs knowledge of the plan to interpret; "3 of 5 datasets fully
 *     protected" does not.
 *
 * Status marks are shape and colour, not glyph soup:
 *   filled green dot   a copy exists
 *   blue sync arrows   a copy is being made right now
 *   filled amber dot   configured target with no copy yet
 *   hollow grey ring   not a target by design
 * An exclamation mark was tried for the amber case and read as "something is
 * broken" rather than "not backed up yet", so it is a plain dot.
 *
 * Element ids are prefixed bw- and are distinct from the page's bo- ids: both
 * can be open in one browser at once, and a shared id would have the tile's 1s
 * tick writing into the page's DOM.
 */
require_once '/usr/local/emhttp/plugins/backup-widget/overview.php';

if (!function_exists('bw_mark')) {
  /* One status mark, fixed size so the three columns stay in line however the
     state changes. */
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
        return ['svg' => "<svg width='11' height='11' viewBox='0 0 12 12'><circle cx='6' cy='6' r='4.3' fill='none' stroke='$grey' stroke-width='1.4'/></svg>",
                'tip' => 'Not configured - this dataset is not meant to go to this cloud'];
    }
  }
}

if (!function_exists('bw_gauge')) {
  /* Circular health gauge. A ring is read at a glance where a percentage has to
     be parsed. pathLength=100 lets the dash array be the percentage directly,
     with no circumference arithmetic to get wrong. */
  function bw_gauge($pct, $colour, $px = 52) {
    $pct = max(0, min(100, (int)$pct));
    return "<svg width='$px' height='$px' viewBox='0 0 36 36' role='img'"
         . " aria-label='Backup health $pct percent'>"
         . "<circle cx='18' cy='18' r='15.5' fill='none' stroke='#e2e8f0' stroke-width='3.4'/>"
         . "<circle cx='18' cy='18' r='15.5' fill='none' stroke='$colour' stroke-width='3.4'"
         . " stroke-linecap='round' pathLength='100' stroke-dasharray='$pct 100'"
         . " transform='rotate(-90 18 18)'/>"
         . "<text x='18' y='20.4' text-anchor='middle' font-size='9.5' font-weight='700'"
         . " fill='$colour'>$pct%</text></svg>";
  }
}

if (!function_exists('bo_render_widget')) {
  function bo_render_widget() {
    $st = bo_state();
    $h  = function ($s) { return htmlspecialchars((string)$s, ENT_QUOTES); };

    $green = '#16a34a'; $red = '#dc2626'; $amber = '#d97706';
    $blue  = '#2563eb'; $grey = '#94a3b8';

    $nMissing = count($st['gaps']);

    /* Datasets fully protected: every cloud a dataset is meant to reach holds a
       copy. An upload in progress does not count yet. */
    $full = 0;
    foreach ($st['rows'] as $r) {
      if ($r['targets'] > 0 && $r['ok'] === $r['targets']) $full++;
    }
    $nRows = count($st['rows']);
    $dsPct = $nRows > 0 ? (int)round($full * 100 / $nRows) : 0;
    $gcol  = $dsPct >= 90 ? $green : ($dsPct >= 50 ? $amber : $red);

    $out = "<div class='bw'>";

    $headline = $nMissing > 0
      ? "<span style='color:$amber;font-weight:700'>$nMissing missing backup"
        . ($nMissing > 1 ? 's' : '') . "</span>"
      : ($st['syncing'] > 0
          ? "<span style='color:$blue;font-weight:700'>{$st['syncing']} copy in progress</span>"
          : "<span style='color:$green;font-weight:700'>fully protected</span>");

    $out .= "<div class='bw-head'>"
          . "<div class='bw-gauge'>" . bw_gauge($dsPct, $gcol)
          . "<div class='bw-gauge-l'>Backup Health</div></div>"
          . "<div class='bw-headtxt'>"
          . "<div class='bw-headline'>$headline</div>"
          . "<div class='bw-sub'><b>$full / $nRows</b> datasets fully protected</div>"
          . "<div class='bw-sub'>" . bo_bytes($st['total_bytes']) . " across $nRows datasets</div>"
          . "</div></div>";

    if ($st['act']) {
      $a   = $st['act'];
      $pct = max(0, min(100, $a['pct']));
      /* Percentage sits inside the filled section so the eye lands on it at the
         leading edge of progress. Below ~14% the fill is too narrow for legible
         text, so it moves out into the track. */
      $inside = $pct >= 14;
      $out .= "<div class='bw-act'>"
            . "<div class='bw-act-l'><b id='bw-name'>" . $h($a['name']) . "</b> "
            . "&#8594; " . $h($a['target'])
            . " <span class='bw-tool'>" . $h($a['tool']) . "</span></div>"
            . "<div class='bw-bar'>"
            . "<div class='bw-bar-f' id='bw-bar' style='width:{$pct}%'>"
            . "<span class='bw-pct-in' id='bw-pct'>" . ($inside ? round($pct) . '%' : '') . "</span>"
            . "</div>"
            . "<span class='bw-pct-out' id='bw-pct-out'>" . ($inside ? '' : round($pct) . '%') . "</span>"
            . "</div>"
            /* Three fixed cells: bytes, rate, ETA. These were space-between and
               drifted apart as the numbers changed width. */
            . "<div class='bw-act-s'>"
            . "<span id='bw-bytes'>" . $h(trim($a['done'] . ' / ' . $a['total'], ' /')) . "</span>"
            . "<span id='bw-rate'>" . $h($a['rate']) . "</span>"
            . "<span>ETA <span id='bw-eta'>" . $h($a['eta'] !== '' ? $a['eta'] : '?') . "</span></span>"
            . "</div></div>";
    } else {
      $out .= "<div class='bw-idle'>No transfer running</div>";
    }

    $cloudLabel = ['g' => 'Google', 'd' => 'Dropbox', 'm' => 'Mail.ru'];
    $cloudFull  = ['g' => 'Google Drive', 'd' => 'Dropbox', 'm' => 'mail.ru'];
    $cloudTool  = ['g' => 'Duplicacy', 'd' => 'rclone', 'm' => 'Duplicacy'];

    $out .= "<div class='bw-grid'>";
    /* Tiny text labels above the marks: the brand icons alone were read as
       belonging to the transfer above rather than heading the columns. */
    $out .= "<div class='bw-gr bw-gh'><span></span>";
    foreach (['g', 'd', 'm'] as $sk) {
      $out .= "<span class='bw-mk' title='" . $h($cloudFull[$sk] . ' via ' . $cloudTool[$sk]) . "'>"
            . bo_brand($sk, 12) . "<span class='bw-cl'>" . $h($cloudLabel[$sk]) . "</span></span>";
    }
    $out .= "</div>";

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
      $out .= "</div>";

      /* Collapsed detail: keeps the tile compact while giving the per-cloud story
         without a trip to the full page. */
      $out .= "<div class='bw-det' id='$did'>";
      foreach (['g', 'd', 'm'] as $sk) {
        if (!isset($r['cells'][$sk])) continue;
        $c = $r['cells'][$sk];
        $state = $c['state'] ?? 'na';
        if ($state === 'na') {
          $txt = "<span style='color:$grey'>not a target</span>";
        } elseif ($state === 'ok') {
          $txt = "<span style='color:$green'>" . bo_when($c['ts'])
               . (($c['rev'] ?? '') !== '' ? " &#183; rev " . $h($c['rev']) : '') . "</span>";
        } elseif ($state === 'syncing') {
          $txt = "<span style='color:$blue'>uploading, " . round($c['pct']) . "%</span>";
        } elseif ($state === 'unknown') {
          $txt = "<span style='color:$grey'>not checked yet</span>";
        } else {
          $txt = "<span style='color:$amber'>never backed up</span>";
        }
        $out .= "<div class='bw-detr'><span>" . $h($cloudFull[$sk])
              . " <span class='bw-tool'>" . $h($cloudTool[$sk]) . "</span></span>"
              . "<span>$txt</span></div>";
      }
      $out .= "<div class='bw-detr bw-detp'><span>/mnt/user/" . $h($r['share']) . "</span>"
            . "<span>" . number_format($r['files']) . " files &#183; " . bo_bytes($r['bytes']) . "</span></div>";
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
