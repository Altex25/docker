<?php
require_once __DIR__ . '/../lib/db.php';
$rows = db()->query('SELECT count(*) n, coalesce(sum(qty),0) total FROM items')->fetch();
$low = db()->query('SELECT name, qty FROM items WHERE qty < 5 ORDER BY qty')->fetchAll();
$body = "Articles: {$rows['n']}, quantité totale: {$rows['total']}\nStock bas:\n";
foreach ($low as $l) { $body .= " - {$l['name']}: {$l['qty']}\n"; }
app_log('info', 'rapport généré');
$sent = @mail(REPORT_TO, 'Rapport stock ' . date('Y-m-d'), $body, ['Content-Type' => 'text/plain; charset=UTF-8']);
app_log($sent ? 'info' : 'error', $sent ? 'rapport envoyé à ' . REPORT_TO . ' via ' . SMTP_HOST : 'échec de l\'envoi du rapport via ' . SMTP_HOST);
echo $body;
exit($sent ? 0 : 1);
