<?PHP
/* 30s poll endpoint for the dashboard tile. Same renderer as the tile's first
   paint, so the two cannot drift. Served under /plugins/, behind emhttp auth. */
require_once '/usr/local/emhttp/plugins/backup-widget/overview-widget.php';
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
echo bo_render_widget();
?>
