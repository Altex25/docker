FROM docker:28.5-dind@sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac

RUN apk add --no-cache openssh-server \
    && adduser -D -h /home/deploy -s /bin/sh deploy \
    && addgroup deploy docker \
    && sed -i 's/^deploy:!/deploy:*/' /etc/shadow \
    && ln -s /usr/local/bin/docker /usr/bin/docker \
    && install -d -o deploy -g deploy -m 0750 /srv/shop \
    && install -d -o deploy -g deploy -m 0700 /home/deploy/.ssh

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/serveur-entrypoint.sh

EXPOSE 22 80
ENTRYPOINT ["serveur-entrypoint.sh"]
CMD ["dockerd", "--host=unix:///var/run/docker.sock"]
