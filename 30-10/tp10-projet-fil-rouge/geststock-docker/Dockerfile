ARG PHP_IMAGE=php:8.3.36-apache-trixie@sha256:11093ce0630a495ce9436647d2939b5ca44b411d2a04917afe8b2d051ae2d2ed

FROM ${PHP_IMAGE} AS base

ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.49
ARG SUPERCRONIC_SHA256_AMD64=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1
ARG SUPERCRONIC_SHA256_ARM64=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN docker-php-ext-install -j"$(nproc)" pdo_mysql \
    && apt-get update \
    && apt-get install -y --no-install-recommends msmtp=1.8.28-3 \
    && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
      amd64) sum=$SUPERCRONIC_SHA256_AMD64 ;; \
      arm64) sum=$SUPERCRONIC_SHA256_ARM64 ;; \
      *) echo "architecture non supportée : $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
    && echo "${sum}  /usr/local/bin/supercronic" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/supercronic

RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && a2enmod headers remoteip \
    && a2disconf other-vhosts-access-log serve-cgi-bin \
    && a2dissite 000-default

COPY docker/php/geststock.ini $PHP_INI_DIR/conf.d/zz-geststock.ini
COPY docker/apache/ports.conf /etc/apache2/ports.conf
COPY docker/apache/geststock.conf /etc/apache2/sites-available/geststock.conf
COPY docker/entrypoint.sh /usr/local/bin/geststock-entrypoint
COPY docker/sendmail.sh /usr/local/bin/geststock-sendmail
COPY docker/crontab /etc/geststock/crontab
COPY docker/rapport-maintenant.sh /usr/local/bin/rapport-maintenant
RUN a2ensite geststock && apache2ctl -t

FROM base AS test
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /src
COPY app ./app
COPY tests ./tests
RUN find app tests -name '*.php' -print0 | xargs -0 -n1 php -l \
    && php tests/config_test.php

FROM base AS runtime

ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/Altex25/geststock-docker
ARG PHP_IMAGE

LABEL org.opencontainers.image.title="geststock" \
      org.opencontainers.image.description="GestStock (inventaire PHP) conteneurisé : Apache + mod_php 8.3" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${PHP_IMAGE}"

ENV APP_VERSION=${APP_VERSION} \
    TZ=Europe/Paris \
    UPLOAD_DIR=/var/www/html/uploads \
    LOG_FILE=php://stderr

COPY --from=test /src/app /var/www/geststock
RUN install -d -o www-data -g www-data -m 0750 /var/www/html/uploads \
    && rm -f /var/www/html/index.html

WORKDIR /var/www/geststock
USER 33:33
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --start-interval=1s --retries=3 \
    CMD ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/?health"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["geststock-entrypoint"]
CMD ["apache2-foreground"]
