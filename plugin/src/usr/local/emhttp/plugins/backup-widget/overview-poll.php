<?PHP
/* 30s poll endpoint: the whole panel, same renderer as the first paint so the
   two cannot drift. Coverage and sizes come from 6-hourly cron files, so there
   is nothing to gain from asking more often than this. */
require_once '/usr/local/emhttp/plugins/backup-widget/overview.php';
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
echo bo_render();
?>
