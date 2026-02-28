COMPOSE = docker compose --env-file infra/.env.example -f infra/docker-compose.yml

.PHONY: dev build test lint

dev:
	$(COMPOSE) up --build

build:
	$(COMPOSE) build

test:
	cd server-app && python3 -m pytest

lint:
	cd server-app && python3 -m ruff check .
