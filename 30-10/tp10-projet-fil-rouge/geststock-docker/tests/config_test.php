<?php
$failures = 0;
function check(string $label, bool $ok): void {
    global $failures;
    echo ($ok ? 'OK     ' : 'ÉCHEC  ') . $label . "\n";
    if (!$ok) { $failures++; }
}

$secret = tempnam(sys_get_temp_dir(), 'secret');
file_put_contents($secret, "s3cr3t-de-test\n");
putenv("DB_PASS_FILE=$secret");
putenv('DB_PASS=ne-doit-pas-servir');
putenv('DB_HOST=db-test');
putenv('UPLOAD_DIR=/data/uploads');
$log = tempnam(sys_get_temp_dir(), 'log');
putenv("LOG_FILE=$log");

require __DIR__ . '/../app/lib/db.php';

check('DB_PASS lu depuis DB_PASS_FILE, sans le saut de ligne final', DB_PASS === 's3cr3t-de-test');
check('DB_HOST lu depuis l\'environnement', DB_HOST === 'db-test');
check('DB_NAME garde sa valeur par défaut', DB_NAME === 'geststock');
check('UPLOAD_DIR normalisé avec un / final', UPLOAD_DIR === '/data/uploads/');
check('config_secret retombe sur la variable sans _FILE', (function () { putenv('X_TEST=valeur'); return config_secret('X_TEST'); })() === 'valeur');
check('config_secret renvoie le défaut si le fichier est illisible', (function () { putenv('Y_TEST_FILE=/inexistant'); return config_secret('Y_TEST', 'defaut'); })() === 'defaut');

app_log('INFO', 'test é "guillemets"');
$entry = json_decode(trim(file_get_contents($log)), true);
check('app_log écrit une ligne JSON', is_array($entry));
check('app_log : level en minuscules, message intact', ($entry['level'] ?? '') === 'info' && ($entry['msg'] ?? '') === 'test é "guillemets"');

unlink($secret);
unlink($log);
exit($failures === 0 ? 0 : 1);
