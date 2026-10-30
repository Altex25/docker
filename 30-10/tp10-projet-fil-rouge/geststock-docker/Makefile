SHELL := bash
COMPOSE := docker compose
PROD := docker compose -f compose.yml -f compose.prod.yml
HARDENED := docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml

.DEFAULT_GOAL := help
.PHONY: help init up down ps logs config rapport mails test backup restore test-restore migrate audit prod-config hardened-config ci

help:
	@echo "make init | up | down | ps | logs | config | rapport | mails | test"
	@echo "make backup | restore B=backups/<horodatage> | test-restore | migrate DUMP=… UPLOADS=…"
	@echo "make audit | prod-config | hardened-config | ci"

init:
	./scripts/init-secrets.sh

up: init
	$(COMPOSE) up -d --build --wait

down:
	$(COMPOSE) down --remove-orphans

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail 50

config: init
	$(COMPOSE) config -q && echo "compose dev OK"

rapport:
	$(COMPOSE) exec rapport rapport-maintenant

mails:
	@curl -s -H 'Host: mail.localhost' http://localhost/api/v1/messages | jq -r '.messages[] | "\(.Created)  \(.To[0].Address)  \(.Subject)"'

test:
	./scripts/smoke-test.sh

backup:
	./scripts/backup.sh

restore:
	@test -n "$(B)" || { echo "usage : make restore B=backups/<horodatage>" >&2; exit 2; }
	./scripts/restore.sh "$(B)"

test-restore:
	./scripts/test-restore.sh

migrate:
	@test -n "$(DUMP)" -a -n "$(UPLOADS)" || { echo "usage : make migrate DUMP=dump.sql UPLOADS=uploads.tar.gz" >&2; exit 2; }
	./scripts/migrate-legacy.sh "$(DUMP)" "$(UPLOADS)"

audit:
	./scripts/audit.sh -p geststock

prod-config: init
	VERSION=$${VERSION:-dev} $(PROD) config -q && echo "compose prod OK"

hardened-config: init
	VERSION=$${VERSION:-dev} $(HARDENED) config -q && echo "compose durci OK"

ci:
	./ci-local.sh pr
