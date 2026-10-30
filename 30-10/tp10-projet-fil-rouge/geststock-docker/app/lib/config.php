<?php
function config_env(string $name, string $default): string {
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
}

function config_secret(string $name, string $default = ''): string {
    $file = getenv($name . '_FILE');
    if ($file === false || $file === '') {
        return config_env($name, $default);
    }
    $value = @file_get_contents($file);
    if ($value === false) {
        error_log("geststock: secret $name illisible ($file)");
        return $default;
    }
    return rtrim($value, "\r\n");
}

define('DB_HOST', config_env('DB_HOST', 'db'));
define('DB_PORT', config_env('DB_PORT', '3306'));
define('DB_NAME', config_env('DB_NAME', 'geststock'));
define('DB_USER', config_env('DB_USER', 'geststock'));
define('DB_PASS', config_secret('DB_PASS'));
define('UPLOAD_DIR', rtrim(config_env('UPLOAD_DIR', '/var/www/html/uploads'), '/') . '/');
define('LOG_FILE', config_env('LOG_FILE', 'php://stderr'));
define('SMTP_HOST', config_env('SMTP_HOST', 'mailpit'));
define('REPORT_TO', config_env('REPORT_TO', 'direction@shop.example'));
define('DRAIN_FILE', config_env('DRAIN_FILE', '/tmp/geststock-drain'));
