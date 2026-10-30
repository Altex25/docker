#!/bin/sh
exec /usr/bin/msmtp --host="${SMTP_HOST:-mailpit}" --port="${SMTP_PORT:-1025}" \
  --from="${MAIL_FROM:-geststock@shop.example}" --auth=off --tls="${SMTP_TLS:-off}" -t "$@"
