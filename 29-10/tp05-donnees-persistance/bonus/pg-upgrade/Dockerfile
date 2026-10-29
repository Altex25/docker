FROM alpine:3.20.10@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
RUN apk add --no-cache postgresql14=14.17-r0 postgresql16=16.14-r0
USER 70:70
WORKDIR /var/lib/postgresql
ENTRYPOINT ["/usr/libexec/postgresql16/pg_upgrade", "-b", "/usr/libexec/postgresql14", "-B", "/usr/libexec/postgresql16", "-d", "/var/lib/postgresql/14/data", "-D", "/var/lib/postgresql/16/data", "-U", "shop"]
