<?PHP
/* 1s poll endpoint: live transfer numbers only.
   Served under /plugins/backup-widget/, so it sits behind emhttp session auth
   and is never reachable unauthenticated.
   Deliberately tiny - a few hundred bytes - because it is fetched every second.
   Reads rclone's rc server plus two small ini files; no shell, no cloud calls. */
require_once '/usr/local/emhttp/plugins/backup-widget/overview.php';
header('Content-Type: application/json');
header('Cache-Control: no-store');
echo json_encode(bo_live_json());
?>
