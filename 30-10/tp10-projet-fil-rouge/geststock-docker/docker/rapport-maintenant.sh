#!/bin/sh
if [ -w /proc/1/fd/2 ] && [ "$$" -ne 1 ]; then
  exec php /var/www/geststock/bin/rapport.php "$@" 2>> /proc/1/fd/2
fi
exec php /var/www/geststock/bin/rapport.php "$@"
