SHELL := bash
COMPOSE := docker compose
PROD := docker compose -f compose.yml -f compose.prod.yml

.DEFAULT_GOAL := help
.PHONY: help init up down ps logs tools watch config prod-config prod-up prod-down prod-ps prod-logs migrate prod-migrate test prod-test

help:
	@echo "make init | up | down | ps | logs | tools | watch | config"
	@echo "make prod-config | prod-up | prod-down | prod-ps | prod-logs"
	@echo "make migrate M=002-add-sku.sql | prod-migrate M=002-add-sku.sql | test | prod-test"

init: .env secrets/db_password.txt apps/shop-worker/pip.conf

.env:
	cp .env.example .env

secrets/db_password.txt:
	mkdir -p secrets
	openssl rand -base64 32 | tr -d '\n/+=' > $@
	chmod 644 $@

apps/shop-worker/pip.conf:
	printf '[global]\nindex-url = https://pypi.org/simple\n' > $@

config: init
	$(COMPOSE) config

up: init
	$(COMPOSE) up -d --build --wait

down:
	$(COMPOSE) --profile tools --profile ops down --remove-orphans

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail 50

tools: init
	$(COMPOSE) --profile tools up -d --wait adminer

watch: init
	$(COMPOSE) -f compose.yml -f compose.override.yml -f compose.watch.yml up -d --build --wait
	$(COMPOSE) -f compose.yml -f compose.override.yml -f compose.watch.yml watch --no-up

prod-config: init
	$(PROD) config

prod-up: init
	$(PROD) up -d --wait --remove-orphans

prod-down:
	$(PROD) down --remove-orphans

prod-ps:
	$(PROD) ps

prod-logs:
	$(PROD) logs -f --tail 50

migrate: init
	@test -n "$(M)" || { echo "usage : make migrate M=002-add-sku.sql" >&2; exit 2; }
	MIGRATION=$(M) $(COMPOSE) --profile ops run --rm migrate

prod-migrate: init
	@test -n "$(M)" || { echo "usage : make prod-migrate M=002-add-sku.sql" >&2; exit 2; }
	MIGRATION=$(M) $(PROD) --profile ops run --rm migrate

test:
	./smoke-test.sh

prod-test:
	COMPOSE="$(PROD)" ./smoke-test.sh
