Ниже — **пошаговый план изменений**, чтобы ваш текущий boilerplate превратился в линейку **`*-postgres-redis` (всё внутри compose)** с нормальным CI/CD-потоком **pull → up → run migrate**, без гонок и с предсказуемыми dev/prod.

---

## Цель и принципы (чтобы не запутаться)

### Что хотим получить
- **`docker-compose.yml` (base)**: *всегда* содержит «инфраструктурное ядро»:
    - `php` + `nginx`
    - `postgres` + `redis`
    - volumes для сокета и данных БД/Redis
    - healthchecks
- **`docker-compose.dev.yml` (dev overlay)**:
    - bind-mount кода
    - порты наружу (nginx, vite, pgadmin, *опционально* db/redis для отладки)
    - node/vite
    - pgAdmin (dev-only)
- **`docker-compose.prod.yml` (prod overlay)**:
    - подмена `php/nginx` на `image` из registry
    - добавление one-off сервиса `migrate` (job) с `php artisan migrate --force`
    - (БД и Redis остаются из base — как вы и описывали)

### Важное правило про данные
- **dev и prod “разные” базы**, потому что volumes разные физически (у вас разные машины).
- В prod база **не должна “обнуляться” на каждом деплое**. Обновление схемы делается миграциями.

---

## Шаг 0. Подготовка (без правок кода)
1) Зафиксируйте текущий working state (ветка/тег).
2) Убедитесь, что в Laravel-проекте вы готовы держать:
    - `DB_CONNECTION=pgsql`
    - `CACHE_STORE` / `SESSION_DRIVER` (если будете завязываться на Redis)

---

## Шаг 1. Добавить Postgres + Redis в base `docker-compose.yml`

**Что делаем**
- Добавляем сервис `laravel-postgres-nginx-socket` (из dev переносим в base).
- Добавляем сервис `laravel-redis-nginx-socket`.
- Добавляем named volumes:
    - `postgres-data`
    - `redis-data` (для Redis AOF, если включите persist)
- Добавляем healthchecks:
    - Postgres: `pg_isready`
    - Redis: `redis-cli ping`

> Почему в base: чтобы **и dev, и prod** имели одинаковое наличие сервисов, а dev overlay только добавлял удобства.

```yaml
services:
  # Laravel PHP-FPM
  laravel-php-nginx-socket:
    build:
      context: ./docker
      dockerfile: php.Dockerfile
      target: php-base
    container_name: laravel-php-nginx-socket
    restart: unless-stopped
    working_dir: /var/www/laravel
    environment:
      XDEBUG_MODE: ${XDEBUG_MODE}
      XDEBUG_START: ${XDEBUG_START}
      XDEBUG_CLIENT_HOST: ${XDEBUG_CLIENT_HOST}
    volumes:
      - unix-socket:/var/run/php
    networks:
      - laravel-php-nginx-socket-network
    healthcheck:
      test: [ "CMD-SHELL", "cgi-fcgi -bind -connect /var/run/php/php-fpm.sock" ]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  # Веб-сервер Nginx
  laravel-nginx-socket:
    build:
      context: ./docker
      dockerfile: nginx.Dockerfile
    container_name: laravel-nginx-socket
    restart: unless-stopped
    volumes:
      - unix-socket:/var/run/php
    networks:
      - laravel-php-nginx-socket-network
    healthcheck:
      test: [ "CMD", "nginx", "-t" ]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    depends_on:
      laravel-php-nginx-socket:
        condition: service_healthy

  # PostgreSQL (base: и для dev, и для prod)
  laravel-postgres-nginx-socket:
    image: postgres:18.2-alpine
    container_name: laravel-postgres-nginx-socket
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_DATABASE}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - laravel-php-nginx-socket-network
    healthcheck:
      test: [ "CMD", "pg_isready" ]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  # Redis (base: и для dev, и для prod)
  laravel-redis-nginx-socket:
    image: redis:7-alpine
    container_name: laravel-redis-nginx-socket
    restart: unless-stopped
    command: [ "redis-server", "--appendonly", "yes" ]
    volumes:
      - redis-data:/data
    networks:
      - laravel-php-nginx-socket-network
    healthcheck:
      test: [ "CMD", "redis-cli", "ping" ]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

volumes:
  unix-socket:
  postgres-data:
  redis-data:

networks:
  laravel-php-nginx-socket-network:
    driver: bridge
```


---

## Шаг 2. Превратить `docker-compose.dev.yml` в «только dev-удобства»

**Что делаем**
- Удаляем Postgres из dev overlay (потому что он уже в base).
- Добавляем *только* публикацию порта Postgres наружу (если нужно подключаться клиентом с хоста).
- Добавляем *только* публикацию порта Redis наружу (если нужно).
- pgAdmin оставляем dev-only, но он будет ходить в `laravel-postgres-nginx-socket` из base.

> Важно: публикация портов — dev-only. В prod обычно не публикуют 5432/6379 наружу.

```yaml
services:
  laravel-php-nginx-socket:
    volumes:
      - .:/var/www/laravel
      - unix-socket:/var/run/php

  laravel-nginx-socket:
    ports:
      - "${NGINX_PORT}:80"
    volumes:
      - .:/var/www/laravel
      - unix-socket:/var/run/php
    depends_on:
      - laravel-node-nginx-socket

  laravel-node-nginx-socket:
    image: node:24-alpine
    container_name: laravel-node-nginx-socket
    working_dir: /var/www/laravel
    volumes:
      - .:/var/www/laravel
      - node_modules:/var/www/laravel/node_modules
    command: >
      sh -lc '
        if [ -f package-lock.json ]; then
          npm ci;
        else
          npm install;
        fi;

        npm run dev -- --host 0.0.0.0 --port 5173
      '
    ports:
      - "5173:5173"
    networks:
      - laravel-php-nginx-socket-network

  # Dev-only: проброс Postgres наружу (если нужен доступ с хоста)
  laravel-postgres-nginx-socket:
    ports:
      - "${DB_FORWARD_PORT}:5432"

  # Dev-only: проброс Redis наружу (если нужен доступ с хоста)
  laravel-redis-nginx-socket:
    ports:
      - "${REDIS_FORWARD_PORT}:6379"

  # Dev-only: pgAdmin
  laravel-pgadmin-nginx-socket:
    image: dpage/pgadmin4:latest
    container_name: laravel-pgadmin-nginx-socket
    restart: unless-stopped
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_DEFAULT_EMAIL}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_DEFAULT_PASSWORD}
    ports:
      - "${PGADMIN_PORT}:80"
    networks:
      - laravel-php-nginx-socket-network
    healthcheck:
      test: [ "CMD", "wget", "-q", "-O", "-", "http://localhost/" ]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 10s
    depends_on:
      laravel-postgres-nginx-socket:
        condition: service_healthy

volumes:
  node_modules:
```


---

## Шаг 3. Добавить переменные в `.env.docker` (для Redis и dev-портов)

**Что делаем**
- Добавляем `REDIS_FORWARD_PORT`.
- Добавляем подсказки по `REDIS_HOST` для compose-режима.
- Не кладём никаких реальных секретов — только примеры/плейсхолдеры.

```dotenv
# ====================================================
# Docker Environment Configuration
# ====================================================
# Настройки для работы в Docker-контейнерах
# Архитектура: PHP-FPM + Nginx (Unix socket) + PostgreSQL + Redis (+ pgAdmin в dev)

# --- pgAdmin Web Interface ---
# Доступ к pgAdmin: http://localhost:8080
PGADMIN_DEFAULT_EMAIL=admin@example.com
PGADMIN_DEFAULT_PASSWORD=admin

# --- Docker ports (host -> container) ---
NGINX_PORT=80
DB_FORWARD_PORT=5432
REDIS_FORWARD_PORT=6379
PGADMIN_PORT=8080

# --- Xdebug Configuration ---
XDEBUG_MODE=off
XDEBUG_START=no
XDEBUG_CLIENT_HOST=host.docker.internal

# --- App .env hints (пример, НЕ секреты) ---
# DB_CONNECTION=pgsql
# DB_HOST=laravel-postgres-nginx-socket
# DB_PORT=5432
# DB_DATABASE=<db_name>
# DB_USERNAME=<db_user>
# DB_PASSWORD=<db_password>
#
# REDIS_HOST=laravel-redis-nginx-socket
# REDIS_PORT=6379
# REDIS_PASSWORD=<redis_password_or_empty>
```


---

## Шаг 4. Расширить `docker-compose.prod.yml`: добавить one-off сервис `migrate`

**Что делаем**
- Добавляем сервис `migrate`, который:
    - использует **тот же PHP image**, что и `laravel-php-nginx-socket`
    - запускает `php artisan migrate --force`
    - ждёт готовности Postgres через `depends_on` (на основании healthcheck из base)

> Трюк: сервис `migrate` можно держать **только в prod overlay**, чтобы не усложнять dev.

```yaml
services:
  laravel-php-nginx-socket:
    image: "${CI_REGISTRY_IMAGE}/php:${IMAGE_TAG}"
    restart: unless-stopped

  laravel-nginx-socket:
    image: "${CI_REGISTRY_IMAGE}/nginx:${IMAGE_TAG}"
    restart: unless-stopped
    ports:
      - "8000:80"

  migrate:
    image: "${CI_REGISTRY_IMAGE}/php:${IMAGE_TAG}"
    restart: "no"
    working_dir: /var/www/laravel
    command: [ "sh", "-lc", "php artisan migrate --force" ]
    depends_on:
      laravel-postgres-nginx-socket:
        condition: service_healthy
```


---

## Шаг 5. Привести `Makefile` в соответствие (Redis + более правильные ожидания)

**Что делаем**
- Добавляем `REDIS_SERVICE`.
- Добавляем `logs-redis`, `shell-redis`.
- В `setup`:
    - ждать Postgres (как и сейчас)
    - Redis обычно ждать не критично для миграций, но для “полной готовности” можно добавить ping.

```makefile
# ==========================================
# Laravel PHP-FPM Nginx Socket (Boilerplate)
# ==========================================

.PHONY: help up down restart build rebuild logs status shell-php shell-nginx shell-postgres shell-redis clean setup artisan migrate laravel-install

# ... existing code ...

# Сервисы (имена сервисов из compose-файлов)
PHP_SERVICE=laravel-php-nginx-socket
NGINX_SERVICE=laravel-nginx-socket
POSTGRES_SERVICE=laravel-postgres-nginx-socket
REDIS_SERVICE=laravel-redis-nginx-socket
PGADMIN_SERVICE=laravel-pgadmin-nginx-socket
NODE_SERVICE=laravel-node-nginx-socket

# ... existing code ...

logs-redis: ## Просмотр логов Redis
	$(COMPOSE) logs -f $(REDIS_SERVICE)

shell-redis: ## Подключиться к Redis CLI
	@echo "$(YELLOW)Подключение к Redis...$(NC)"
	$(COMPOSE) exec $(REDIS_SERVICE) redis-cli ping

# ... existing code ...

setup: ## Полная инициализация проекта с нуля
	@make build
	@make up
	@echo "$(YELLOW)Ожидание готовности PostgreSQL...$(NC)"
	@$(COMPOSE) exec $(POSTGRES_SERVICE) sh -c 'until pg_isready; do sleep 1; done'
	@echo "$(YELLOW)Ожидание готовности Redis...$(NC)"
	@$(COMPOSE) exec $(REDIS_SERVICE) sh -c 'until redis-cli ping | grep -q PONG; do sleep 1; done'
	@make install-deps
	@make artisan CMD="key:generate"
	@make migrate
	@make permissions
	@make cleanup-nginx
	@echo "$(GREEN)✓ Проект готов: http://localhost$(NC)"

# ... existing code ...

info: ## Показать информацию о проекте
	@echo "$(YELLOW)Laravel-Nginx-Socket Development Environment$(NC)"
	@echo "======================================"
	@echo "$(GREEN)Сервисы:$(NC)"
	@echo "  • PHP-FPM (Alpine)"
	@echo "  • Nginx"
	@echo "  • PostgreSQL"
	@echo "  • Redis"
	@echo "  • pgAdmin 4 (dev only)"
	@echo ""
	@echo "$(GREEN)Порты:$(NC)"
	@echo "  • 80   - Nginx (Web Server)"
	@echo "  • 5432 - PostgreSQL (dev forwarded)"
	@echo "  • 6379 - Redis (dev forwarded)"
	@echo "  • 8080 - pgAdmin (dev only)"
	@echo "  • Unix Socket - Связь PHP-FPM <-> Nginx"
```


---

## Шаг 6. Обновить README/SETUP: описать Redis и CI/CD миграции

**Что описать**
- Какие переменные нужно задать в `.env` Laravel для работы с compose:
    - `DB_HOST=laravel-postgres-nginx-socket`
    - `REDIS_HOST=laravel-redis-nginx-socket`
- Как запускать dev:
    - `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build`
- Как выглядит prod deploy sequence:
    1) `docker compose ... pull`
    2) `docker compose ... up -d`
    3) `docker compose ... run --rm migrate`

(Если хотите — я дам точный текст блоков для README/SETUP под ваш стиль.)

---

## Шаг 7. CI/CD порядок команд (канон) и защита от гонок

### Канонический порядок на сервере в деплой-job
```shell script
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
docker compose -f docker-compose.yml -f docker-compose.prod.yml run --rm migrate
```


### Как не словить “гонки”
- Деплой в GitLab должен быть **серийным** для одного окружения (обычно GitLab environments это умеют; либо ваш deploy template/ansible-starter уже это делает).
- Никогда не запускайте два `migrate` параллельно на один и тот же Postgres.

---

## Контрольные проверки после каждого шага

1) **Merged config** (самое полезное при overlay-подходе):
    - dev: итогово должны быть php/nginx/node/postgres/redis/pgadmin
    - prod: итогово php/nginx/postgres/redis/migrate, без node/pgadmin, без bind-mount
2) **Dev smoke**:
    - сайт открывается
    - `php artisan migrate` работает
    - кеш/очереди (если используете) видят Redis
3) **Prod smoke** (локальная имитация, по желанию):
    - `up -d` + `run --rm migrate` без ошибок

---

Если вы скажете, какой Redis-режим хотите “по умолчанию” в boilerplate:
1) **простая dev-friendly конфигурация** (как выше, `appendonly yes`, без пароля), или
2) **приближенная к prod** (пароль, ACL, ограничение доступа, возможно отдельный конфиг)

— я под это подстрою финальные compose-кусочки и рекомендации для `.env` Laravel (cache/session/queue).