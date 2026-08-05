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
 *   - No "Attention required" headline. Above a count that already says what is
 *     wrong it was pure redundancy in a tile with no spare room.
 *   - Score per dataset, averaged, half credit for uploads in progress. Counting
 *     "datasets where every target is present" read 40% for an estate that was
 *     genuinely fine, and a metric that overstates danger gets ignored just like
 *     one that understates it. See bo_score().
 *
 * Status marks are one family of dots, GitHub-Actions style, because a row of
 * mixed glyphs is slower to read than a row of dots in different colours:
 *   filled green dot   a copy exists
 *   blue sync arrows   a copy is being made right now
 *   filled amber dot   configured target with no copy yet
 *   pale grey dot      not a target by design
 * Three things were tried and rejected for that last state: an exclamation mark
 * (read as "broken"), a hollow ring (read as "inactive"), and a dash (read as
 * missing data rather than not-applicable).
 *
 * Syncing counts as green in the breakdown, not blue: a copy actively being
 * produced is a healthy state, and blue reads as merely informational.
 *
 * Element ids are prefixed bw- and are distinct from the page's bo- ids: both can
 * be open in one browser at once, and a shared id would have the tile's 1s tick
 * writing into the page's DOM.
 */
require_once '/usr/local/emhttp/plugins/backup-widget/overview.php';

if (!function_exists('bw_mark')) {
  /* Delegates to bo_mark() in overview.php. The tile used to carry its own copy of
     these five dots, which is exactly how a page and a tile end up disagreeing
     about what green means. One definition, two callers. */
  function bw_mark($state, $green = null, $amber = null, $blue = null, $grey = null) {
    return bo_mark($state, 13);
  }
}

if (!function_exists('bw_gauge')) {
  /* Ring gauge. Larger and thinner than the first attempt: at stroke 3.4 a red or
     amber ring dominated a tile it only needs to lead. pathLength=100 lets the
     dash array be the percentage directly, with no circumference arithmetic. */
  function bw_gauge($pct, $colour, $px = 61, $pending = false) {
    $pct = max(0, min(100, (int)$pct));
    $label = $pending ? 'Protection score pending' : "Protection score $pct percent";
    $text  = $pending ? '?' : "$pct%";
    return "<svg width='$px' height='$px' viewBox='0 0 36 36' role='img'"
         . " aria-label='$label'>"
         . "<circle cx='18' cy='18' r='16' fill='none' stroke='#e2e8f0' stroke-width='2.2'/>"
         . "<circle cx='18' cy='18' r='16' fill='none' stroke='$colour' stroke-width='2.2'"
         . " stroke-linecap='round' pathLength='100' stroke-dasharray='$pct 100'"
         . " transform='rotate(-90 18 18)'/>"
         . "<text x='18' y='20.6' text-anchor='middle' font-size='9.5' font-weight='700'"
         . " fill='$colour'>$text</text></svg>";
  }
}

if (!function_exists('bo_render_widget')) {
  function bo_render_widget() {
    $st = bo_state();
    $h  = function ($s) { return htmlspecialchars((string)$s, ENT_QUOTES); };

    $green = '#16a34a'; $red = '#dc2626'; $amber = '#b45309';   // softened from #d97706: less saturated reads calmer
    $blue  = '#2563eb'; $grey = '#94a3b8';

    $q        = bo_score($st);
    $nMissing = count($st['gaps']);
    $coveragePending = (($st['cov_updated'] ?? 'never') === 'never');
    $gcol     = $coveragePending ? $grey
              : ($q['pct'] >= 90 ? $green : ($q['pct'] >= 60 ? $amber : $red));

    $out = "<div class='bw'>";

    /* Nothing configured is a state of its own, not a score of zero. Without this
       a fresh install - or an operator who unticked everything - got a gauge, a
       breakdown and an empty grid, all describing nothing. */
    if (!$st['rows']) {
      $out .= "<div class='bw-empty'>"
            . bo_icon('shield', 22, $grey)
            . "<div><b>No datasets configured</b>"
            . "<div class='bw-sub'>Choose which shares to watch and which clouds each one "
            . "should reach.</div>"
            . "<a class='bw-open' href='/Utilities/BackupWidget'>Open settings &#8594;</a>"
            . "</div></div>";
      return $out . "</div>";
    }

    /* ---- gauge, status line, breakdown ---- */
    /* No separate headline. "Attention required" above a count that already says
       what is wrong was one line of redundancy in a tile with no spare room; the
       score label plus the count carries it. */
    if ($coveragePending) {
      $status = "coverage check pending";
      $scol   = $grey;
    } elseif ($nMissing > 0 || $q['none'] > 0 || $q['partial'] > 0) {
      $affected = max($nMissing, $q['none'] + $q['partial']);
      $status = "$affected dataset" . ($affected > 1 ? 's need' : ' needs') . " attention";
      $scol   = $amber;
    } elseif ($st['syncing'] > 0) {
      $status = $st['syncing'] . " upload" . ($st['syncing'] > 1 ? 's' : '') . " in progress";
      $scol   = $green;
    } else {
      $status = "every configured target holds a copy";
      $scol   = $green;
    }

    /* Breakdown. Syncing is green, not blue: a copy actively being produced is a
       healthy state, and blue reads as merely informational. */
    $bits = [];
    if ($coveragePending) {
      $bits[] = "<span style='color:$grey'>checking configured targets</span>";
    } else {
      if ($q['full'])    $bits[] = "<span style='color:$green'>{$q['full']} full</span>";
      if ($q['syncing']) $bits[] = "<span style='color:$green'>{$q['syncing']} syncing</span>";
      if ($q['partial']) $bits[] = "<span style='color:$amber'>{$q['partial']} partial</span>";
      if ($q['none'])    $bits[] = "<span style='color:$red'>{$q['none']} none</span>";
    }
    if (!empty($st['paused'])) $bits[] = "<span style='color:$grey'>{$st['paused']} paused</span>";

    $out .= "<div class='bw-head'>"
          . "<div class='bw-gauge'>" . bw_gauge($q['pct'], $gcol, 61, $coveragePending)
          . "<div class='bw-gauge-l'>Backup score</div></div>"
          . "<div class='bw-headtxt'>"
          . "<div class='bw-status' style='color:$scol'>$status</div>"
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
    $dropboxTool = bo_mirrored() ? 'Duplicacy / rclone' : 'Duplicacy';
    $cloudTool  = ['g' => 'Duplicacy', 'd' => $dropboxTool, 'm' => 'Duplicacy'];

    $out .= "<div class='bw-grid'>";
    $out .= "<div class='bw-gr bw-gh'><span></span>";
    foreach (['g', 'd', 'm'] as $sk) {
      $out .= "<span class='bw-mk' title='" . $h($cloudFull[$sk] . ' via ' . $cloudTool[$sk]) . "'>"
            . bo_brand($sk, 14) . "<span class='bw-cl'>" . $h($cloudLabel[$sk]) . "</span></span>";
    }
    $out .= "<span class='bw-spk-h' title='State at each of the last 14 coverage checks'>history</span></div>";

    foreach ($st['rows'] as $r) {
      $did = 'bw-d-' . preg_replace('/[^a-z0-9]+/i', '-', $r['share']);
      $out .= "<div class='bw-gr bw-row' onclick=\"bwToggle('$did')\" title='Click for detail'>"
            . "<span class='bw-ds'>" . bo_icon($r['icon'], 13, $r['tint'])
            . "<span class='bw-dsn'>" . $h($r['title'])
            . (!empty($r['paused']) ? " <span class='bw-pause'>Paused</span>" : "")
            . "</span></span>";
      foreach (['g', 'd', 'm'] as $sk) {
        $c = $r['cells'][$sk];
        $state = $c['state'] ?? 'na';
        $m = bw_mark($state, $green, $amber, $blue, $grey);

        /* Multi-line tooltip: everything you would otherwise expand the row for,
           with no extra UI. Native title attributes honour newlines. */
        $cellTool = isset($c['tool']) ? bo_tool_label($c['tool']) : $cloudTool[$sk];
        $tip = $cloudFull[$sk] . " - " . $cellTool . "\n";
        if ($state === 'ok') {
          $tip .= "Last backup: " . strip_tags(bo_when($c['ts']));
          if (($c['rev'] ?? '') !== '') $tip .= " (revision {$c['rev']})";
        } elseif ($state === 'syncing') {
          $tip .= "Uploading now: " . round($c['pct']) . "% of bytes present";
        } elseif ($state === 'missing') {
          $tip .= "Never backed up\nTarget is configured but has received nothing yet";
        } elseif ($state === 'unknown') {
          $tip .= "Not checked since boot";
        } elseif ($state === 'paused') {
          $tip .= "Cloud backup paused by policy";
        } else {
          $tip .= "Not configured\nThis dataset is not sent to this cloud";
        }
        $tip .= "\nSource: " . bo_repo_root($r['share']);

        $out .= "<span class='bw-mk' title='" . $h($tip) . "'>" . $m['svg'] . "</span>";
      }
      $out .= "<span class='bw-spk'>" . (!empty($r['paused'])
            ? "<span class='bw-paused-history'>paused</span>"
            : bo_sparkline($r['share'])) . "</span>";
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
        } elseif ($state === 'paused') {
          $txt = "<span style='color:#64748b'>paused</span>";
        } else {
          $txt = "<span style='color:$amber'>never backed up</span>";
        }

        $out .= "<div class='bw-detr'>"
              . "<span class='bw-detc'>" . $h($cloudFull[$sk])
              . " <span class='bw-tool'>" . $h(isset($c['tool']) ? bo_tool_label($c['tool']) : $cloudTool[$sk]) . "</span></span>"
              . "<span class='bw-dets'>" . $m['svg'] . " $txt</span>"
              . "</div>";
      }
      /* Labelled history inside the expansion. The collapsed sparkline is
         necessarily terse; here there is room to say what it is. */
      $out .= "<div class='bw-hist'><span class='bw-histl'>History</span>"
            . "<span>" . bo_sparkline($r['share'], 14, 5) . "</span></div>";
      $out .= "<div class='bw-detr bw-detp'>"
            . "<span class='bw-detc'>" . $h(bo_repo_root($r['share'])) . "</span>"
            . "<span class='bw-dets'>" . number_format($r['files']) . " files &#183; "
            . bo_bytes($r['bytes']) . "</span></div>";
      $out .= "</div>";
    }
    $out .= "</div>";


    /* ---- how much room is left at each provider ---- */
    /* Coverage answers "is there a copy". This answers "will the next one fit",
       which is the other way the estate fails quietly - a full provider does not
       break a backup loudly, it just stops accepting new data.
       Placed under the grid and using the same three clouds in the same order, so
       a column reads top to bottom as one provider. */
    $qt = bo_quota();
    $out .= "<div class='bw-q'>";
    $out .= "<div class='bw-ql'><span>Space left</span><span class='bw-qu'>"
          . $h($qt['updated'] !== '' ? $qt['updated'] : 'not measured') . "</span></div>";
    $out .= "<div class='bw-qg'>";
    foreach (['g', 'd', 'm'] as $sk) {
      $x = $qt[$sk] ?? null;
      if (!$x) {
        /* No figures is said, not drawn. An empty bar here would read as a full
           provider, which is the alarm this panel exists to raise honestly. */
        $out .= "<div class='bw-qc' title='" . $h($cloudFull[$sk]) . " - no figures from the last check'>"
              . "<div class='bw-qh'>" . bo_brand($sk, 11)
              . "<span class='bw-qf' style='color:$grey'>&#8211;</span></div>"
              . "<div class='bw-qb'></div></div>";
        continue;
      }
      $col = bo_quota_colour($x);
      $tip = $cloudFull[$sk] . "\n"
           . bo_bytes($x['free']) . " free of " . bo_bytes($x['total']) . "\n"
           . bo_bytes($x['used']) . " used";
      if ($x['other'] > 0) {
        $tip .= "\nof which " . bo_bytes($x['other'])
              . " is other data on the same quota, not backups";
      }
      /* A carried-over figure is marked, not hidden. Without the mark the tile
         would report an hour-old number as if it had just been measured. */
      $flag = '';
      if ($x['stale']) {
        $tip .= "\nThe last check could not reach this provider - figures are from "
              . ($x['at'] > 0 ? strip_tags(bo_ago($x['at'])) : 'an earlier run');
        $flag = "<span class='bw-qs' style='color:$amber'>&#8226;</span>";
      }
      $out .= "<div class='bw-qc' title='" . $h($tip) . "'>"
            . "<div class='bw-qh'>" . bo_brand($sk, 11)
            . "<span class='bw-qf'>" . bo_bytes($x['free']) . "</span>$flag</div>"
            . "<div class='bw-qb'><i style='width:{$x['pct']}%;background:$col'></i></div>"
            . "</div>";
    }
    $out .= "</div></div>";

    [$nextTs, $nextWhat] = bo_next_run();
    /* One action, and it goes where the answers are. There is no Duplicacy web UI
       on this host to link to, and an endpoint that runs backups from a web page
       is a security surface this deliberately does not have - so the link opens
       the full overview, which has the per-cloud detail and the attention list. */
    $out .= "<div class='bw-foot'>"
          . "<span>next " . $h(date('H:i', $nextTs)) . " " . $h($nextWhat)
          . " &#183; checked " . $h($st['cov_updated']) . "</span>"
          . "<a class='bw-open' href='/Tools/BackupOverview' title='Open the full backup overview'>"
          . "details &#8594;</a></div>";

    return $out . "</div>";
  }
}

if (!function_exists('bo_widget_header')) {
  function bo_widget_header() {
    $st = bo_state();
    $running = (bool)$st['act'];
    $missing = count($st['gaps']);
    $colour  = $running ? '#2563eb' : ($missing ? '#b45309' : '#16a34a');
    $label   = $running ? 'transferring' : ($missing ? 'action needed' : 'protected');
    return "<span style='color:$colour'>&#9679;</span> "
         . "<span style='font-weight:normal;opacity:.7'>$label</span>";
  }
}
?>
