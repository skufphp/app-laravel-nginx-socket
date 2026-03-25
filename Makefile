# ==========================================
# Laravel PHP-FPM Nginx Socket (Boilerplate)
# ==========================================

.PHONY: \
	help check-files check-files-prod \
	up up-prod down down-prod restart build rebuild rebuild-prod \
	logs logs-prod logs-php logs-php-prod logs-postgres logs-postgres-prod logs-pgadmin logs-node logs-redis logs-redis-prod logs-queue logs-queue-prod logs-scheduler logs-scheduler-prod logs-nginx logs-nginx-prod \
	status \
	shell shell-prod shell-node shell-postgres shell-postgres-prod shell-redis shell-redis-prod shell-queue shell-queue-prod shell-scheduler shell-scheduler-prod shell-php shell-php-prod shell-nginx shell-nginx-prod \
	setup install-deps \
	composer-install composer-update composer-require \
	npm-install npm-dev npm-build \
	artisan composer migrate rollback fresh tinker test-php test-coverage \
	permissions info validate \
	clean clean-all dev-reset clean-prod clean-all-prod prod-reset

# Цвета для вывода
YELLOW=\033[0;33m
GREEN=\033[0;32m
RED=\033[0;31m
NC=\033[0m

# Переменные Compose
COMPOSE = docker compose -f docker-compose.yml
COMPOSE_PROD = docker compose --env-file .env.production -f docker-compose.prod.local.yml

NGINX_PORT := $(shell grep '^NGINX_PORT=' .env 2>/dev/null | cut -d '=' -f 2- | tr -d '[:space:]')
ifeq ($(NGINX_PORT),)
NGINX_PORT := 8050
endif

# Сервисы (имена сервисов из compose-файлов)
PHP_SERVICE=laravel-php-nginx-uds
NGINX_SERVICE=laravel-nginx-uds
POSTGRES_SERVICE=laravel-postgres-nginx-uds
REDIS_SERVICE=laravel-redis-nginx-uds
PGADMIN_SERVICE=laravel-pgadmin-nginx-uds
NODE_SERVICE=laravel-node-nginx-uds
QUEUE_SERVICE=laravel-queue-nginx-uds
SCHEDULER_SERVICE=laravel-scheduler-nginx-uds

help: ## Показать справку
	@echo "$(YELLOW)Laravel PHP-FPM and Nginx Docker Boilerplate with Unix Socket$(NC)"
	@echo "======================================"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "$(GREEN)%-20s$(NC) %s\n", $$1, $$2}'

check-files: ## Проверить наличие всех необходимых файлов
	@echo "$(YELLOW)Проверка файлов конфигурации...$(NC)"
	@test -f docker-compose.yml || (echo "$(RED)✗ docker-compose.yml не найден$(NC)" && exit 1)
	@test -f docker-compose.prod.yml || (echo "$(RED)✗ docker-compose.prod.yml не найден$(NC)" && exit 1)
	@test -f .env || (echo "$(RED)✗ .env не найден. Убедитесь, что вы настроили проект Laravel$(NC)" && exit 1)
	@test -f docker/php.Dockerfile || (echo "$(RED)✗ docker/php.Dockerfile не найден$(NC)" && exit 1)
	@test -f docker/nginx.Dockerfile || (echo "$(RED)✗ docker/nginx.Dockerfile не найден$(NC)" && exit 1)
	@test -f docker/php/php.ini || (echo "$(RED)✗ docker/php/php.ini не найден$(NC)" && exit 1)
	@test -f docker/nginx/conf.d/laravel.conf || (echo "$(RED)✗ docker/nginx/conf.d/laravel.conf не найден$(NC)" && exit 1)
	@echo "$(GREEN)✓ Все файлы на месте$(NC)"

check-files-prod: ## Проверить наличие всех необходимых файлов
	@echo "$(YELLOW)Проверка файлов конфигурации...$(NC)"
	@test -f docker-compose.prod.local.yml || (echo "$(RED)✗ docker-compose.prod.local.yml не найден$(NC)" && exit 1)
	@test -f .env.production || (echo "$(RED)✗ .env.production не найден. Создайте его из .env.production.example$(NC)" && exit 1)
	@test -f docker/php.Dockerfile || (echo "$(RED)✗ docker/php.Dockerfile не найден$(NC)" && exit 1)
	@test -f docker/nginx.Dockerfile || (echo "$(RED)✗ docker/nginx.Dockerfile не найден$(NC)" && exit 1)
	@test -f docker/php/php.prod.ini || (echo "$(RED)✗ docker/php/php.prod.ini не найден$(NC)" && exit 1)
	@test -f docker/nginx/conf.d/laravel.conf || (echo "$(RED)✗ docker/nginx/conf.d/laravel.conf не найден$(NC)" && exit 1)
	@echo "$(GREEN)✓ Все файлы на месте$(NC)"

up: check-files ## Запустить контейнеры (Dev)
	$(COMPOSE) up -d
	@echo "$(GREEN)✓ Проект запущен на http://localhost:$(NGINX_PORT)$(NC)"

up-prod: check-files-prod ## Запустить контейнеры (Prod)
	$(COMPOSE_PROD) up -d
	@echo "$(GREEN)✓ Проект (Prod) запущен$(NC)"

down: ## Остановить контейнеры
	$(COMPOSE) down

down-prod: ## Остановить контейнеры (Prod)
	$(COMPOSE_PROD) down

restart: ## Перезапустить контейнеры
	$(COMPOSE) restart

build: ## Собрать образы (Dev)
	$(COMPOSE) build

rebuild: ## Пересобрать образы без кэша (Dev)
	$(COMPOSE) build --no-cache

rebuild-prod: ## Пересобрать prod образы без кэша
	$(COMPOSE_PROD) build --no-cache

logs: ## Показать логи
	$(COMPOSE) logs -f

logs-prod: ## Показать логи всех сервисов (Prod)
	$(COMPOSE_PROD) logs -f

logs-php: ## Просмотр логов PHP-FPM
	$(COMPOSE) logs -f $(PHP_SERVICE)

logs-php-prod: ## Просмотр логов PHP-FPM (Prod)
	$(COMPOSE_PROD) logs -f $(PHP_SERVICE)

logs-nginx: ## Просмотр логов Nginx
	$(COMPOSE) logs -f $(NGINX_SERVICE)

logs-nginx-prod: ## Просмотр логов Nginx
	$(COMPOSE_PROD) logs -f $(NGINX_SERVICE)

logs-postgres: ## Просмотр логов PostgreSQL
	$(COMPOSE) logs -f $(POSTGRES_SERVICE)

logs-postgres-prod: ## Просмотр логов PostgreSQL (Prod)
	$(COMPOSE_PROD) logs -f $(POSTGRES_SERVICE)

logs-pgadmin: ## Просмотр логов pgAdmin
	$(COMPOSE) logs -f $(PGADMIN_SERVICE)

logs-node: ## Просмотр логов Node (HMR)
	$(COMPOSE) logs -f $(NODE_SERVICE)

logs-redis: ## Просмотр логов Redis
	$(COMPOSE) logs -f $(REDIS_SERVICE)

logs-redis-prod: ## Просмотр логов Redis (Prod)
	$(COMPOSE_PROD) logs -f $(REDIS_SERVICE)

logs-queue: ## Просмотр логов Queue Worker
	$(COMPOSE) logs -f $(QUEUE_SERVICE)

logs-queue-prod: ## Просмотр логов Queue Worker (Prod)
	$(COMPOSE_PROD) logs -f $(QUEUE_SERVICE)

logs-scheduler: ## Просмотр логов Scheduler
	$(COMPOSE) logs -f $(SCHEDULER_SERVICE)

logs-scheduler-prod: ## Просмотр логов Scheduler (Prod)
	$(COMPOSE_PROD) logs -f $(SCHEDULER_SERVICE)

status: ## Статус контейнеров
	$(COMPOSE) ps

shell-php: ## Войти в контейнер PHP
	$(COMPOSE) exec $(PHP_SERVICE) sh

shell-php-prod: ## Войти в контейнер PHP
	$(COMPOSE_PROD) exec $(PHP_SERVICE) sh

shell-nginx: ## Подключиться к контейнеру Nginx
	$(COMPOSE) exec $(NGINX_SERVICE) sh

shell-nginx-prod: ## Подключиться к контейнеру Nginx
	$(COMPOSE_PROD) exec $(NGINX_SERVICE) sh

shell-node: ## Подключиться к контейнеру Node
	$(COMPOSE) exec $(NODE_SERVICE) sh

shell-queue: ## Войти в контейнер Queue Worker
	$(COMPOSE) exec $(QUEUE_SERVICE) sh

shell-queue-prod: ## Войти в контейнер Queue Worker (Prod)
	$(COMPOSE_PROD) exec $(QUEUE_SERVICE) sh

shell-scheduler: ## Войти в контейнер Scheduler
	$(COMPOSE) exec $(SCHEDULER_SERVICE) sh

shell-scheduler-prod: ## Войти в контейнер Scheduler (Prod)
	$(COMPOSE_PROD) exec $(SCHEDULER_SERVICE) sh

shell-postgres: ## Подключиться к PostgreSQL CLI
	@echo "$(YELLOW)Подключение к базе...$(NC)"
	@DB_USER=$$(grep '^DB_USERNAME=' .env | cut -d '=' -f 2- | tr -d '[:space:]'); \
	DB_NAME=$$(grep '^DB_DATABASE=' .env | cut -d '=' -f 2- | tr -d '[:space:]'); \
	$(COMPOSE) exec $(POSTGRES_SERVICE) psql -U $$DB_USER -d $$DB_NAME

shell-postgres-prod: ## Подключиться к PostgreSQL CLI (Prod)
	@echo "$(YELLOW)Подключение к базе (Prod)...$(NC)"
	@DB_USER=$$(grep '^DB_USERNAME=' .env.production | cut -d '=' -f 2- | tr -d '[:space:]'); \
	DB_NAME=$$(grep '^DB_DATABASE=' .env.production | cut -d '=' -f 2- | tr -d '[:space:]'); \
	$(COMPOSE_PROD) exec $(POSTGRES_SERVICE) psql -U $$DB_USER -d $$DB_NAME

shell-redis: ## Подключиться к Redis CLI
	@echo "$(YELLOW)Подключение к Redis...$(NC)"
	@REDIS_PASSWORD=$$(grep '^REDIS_PASSWORD=' .env 2>/dev/null | cut -d '=' -f 2- | tr -d '[:space:]'); \
	if [ -n "$$REDIS_PASSWORD" ]; then \
		$(COMPOSE) exec $(REDIS_SERVICE) redis-cli -a "$$REDIS_PASSWORD" ping; \
	else \
		$(COMPOSE) exec $(REDIS_SERVICE) redis-cli ping; \
	fi

shell-redis-prod: ## Подключиться к Redis CLI (Prod)
	@echo "$(YELLOW)Подключение к Redis (Prod)...$(NC)"
	@REDIS_PASSWORD=$$(grep '^REDIS_PASSWORD=' .env.production 2>/dev/null | cut -d '=' -f 2- | tr -d '[:space:]'); \
	if [ -n "$$REDIS_PASSWORD" ]; then \
		$(COMPOSE_PROD) exec $(REDIS_SERVICE) redis-cli -a "$$REDIS_PASSWORD" ping; \
	else \
		$(COMPOSE_PROD) exec $(REDIS_SERVICE) redis-cli ping; \
	fi

# --- Команды Laravel ---

setup: ## Полная инициализация проекта с нуля
	@make build
	@make up
	@echo "$(YELLOW)Ожидание готовности PostgreSQL...$(NC)"
	@$(COMPOSE) exec $(POSTGRES_SERVICE) sh -c 'until pg_isready; do sleep 1; done'
	@echo "$(YELLOW)Ожидание готовности Redis...$(NC)"
	@REDIS_PASSWORD=$$(grep '^REDIS_PASSWORD=' .env 2>/dev/null | cut -d '=' -f 2- | tr -d '[:space:]'); \
	if [ -n "$$REDIS_PASSWORD" ]; then \
		$(COMPOSE) exec $(REDIS_SERVICE) sh -c "until redis-cli -a '$$REDIS_PASSWORD' ping | grep -q PONG; do sleep 1; done"; \
	else \
		$(COMPOSE) exec $(REDIS_SERVICE) sh -c 'until redis-cli ping | grep -q PONG; do sleep 1; done'; \
	fi
	@make install-deps
	@make artisan CMD="key:generate"
	@make migrate
	@make permissions
	@make cleanup-nginx
	@echo "$(GREEN)✓ Проект готов: http://localhost:$(NGINX_PORT)$(NC)"

install-deps: ## Установка всех зависимостей (Composer + NPM)
	@echo "$(YELLOW)Установка зависимостей...$(NC)"
	@$(MAKE) composer-install
	@$(MAKE) npm-install

# --- Команды Composer ---

composer-install: ## Установить зависимости через Composer
	$(COMPOSE) exec $(PHP_SERVICE) composer install

composer-update: ## Обновить зависимости через Composer
	$(COMPOSE) exec $(PHP_SERVICE) composer update

composer-require: ## Установить пакет через Composer (make composer-require PACKAGE=vendor/package)
	$(COMPOSE) exec $(PHP_SERVICE) composer require $(PACKAGE)

composer: ## Запустить команду composer (make composer CMD="install")
	$(COMPOSE) exec $(PHP_SERVICE) composer $(CMD)

# --- Команды NPM ---

npm-install: ## Установить NPM зависимости
	$(COMPOSE) exec $(NODE_SERVICE) npm install

npm-dev: ## Запустить Vite в режиме разработки (hot reload)
	$(COMPOSE) exec $(NODE_SERVICE) npm run dev

npm-build: ## Собрать фронтенд (внутри PHP контейнера для prod-like билда или dev)
	$(COMPOSE) exec $(NODE_SERVICE) npm run build

# --- Команды Artisan ---

artisan: ## Запустить команду artisan (make artisan CMD="migrate")
	$(COMPOSE) exec $(PHP_SERVICE) php artisan $(CMD)

migrate: ## Запустить миграции
	$(COMPOSE) exec $(PHP_SERVICE) php artisan migrate

rollback: ## Откатить миграции
	$(COMPOSE) exec $(PHP_SERVICE) php artisan migrate:rollback

fresh: ## Пересоздать базу и запустить сиды
	$(COMPOSE) exec $(PHP_SERVICE) php artisan migrate:fresh --seed

tinker: ## Запустить Laravel Tinker
	$(COMPOSE) exec $(PHP_SERVICE) php artisan tinker

test-php: ## Запустить тесты PHP (PHPUnit)
	$(COMPOSE) exec $(PHP_SERVICE) php artisan test

test-coverage: ## Запустить тесты с покрытием кода
	$(COMPOSE) exec $(PHP_SERVICE) php artisan test --coverage

# --- Утилиты ---

permissions: ## Исправить права доступа для Laravel (storage/cache)
	@echo "$(YELLOW)Исправление прав доступа...$(NC)"
	$(COMPOSE) exec $(PHP_SERVICE) sh -c "if [ -d storage ]; then chown -R www-data:www-data storage bootstrap/cache && chmod -R ug+rwX storage bootstrap/cache; fi"
	@echo "$(GREEN)✓ Права доступа исправлены$(NC)"

cleanup-nginx: ## Удалить .htaccess (не нужен для Nginx)
	@echo "$(YELLOW)Удаление .htaccess (не используется с Nginx)...$(NC)"
	@if [ -f public/.htaccess ]; then \
		rm public/.htaccess && echo "$(GREEN)✓ .htaccess удален$(NC)"; \
	else \
		echo "$(GREEN)✓ .htaccess уже отсутствует$(NC)"; \
	fi

info: ## Показать информацию о проекте
	@echo "$(YELLOW)Laravel-Nginx-Socket Development Environment$(NC)"
	@echo "======================================"
	@echo "$(GREEN)Сервисы:$(NC)"
	@echo "  • PHP-FPM 8.5 (Alpine)"
	@echo "  • Nginx"
	@echo "  • PostgreSQL 18.2"
	@echo "  • Redis 8.6"
	@echo "  • Queue Worker"
	@echo "  • Scheduler (cron)"
	@echo "  • pgAdmin 4 (dev only)"
	@echo ""
	@echo "$(GREEN)Структура:$(NC)"
	@echo "  • docker/           - Dockerfiles и конфиги сервисов"
	@echo "  • .env              - единый файл настроек (Laravel + Docker)"
	@echo ""
	@echo "$(GREEN)Порты:$(NC)"
	@echo "  • $(NGINX_PORT) - Nginx (Web Server)"
	@echo "  • 5432 - PostgreSQL (dev forwarded)"
	@echo "  • 6379 - Redis (dev forwarded)"
	@echo "  • 8080 - pgAdmin (dev only)"
	@echo "  • Unix Socket - Связь PHP-FPM <-> Nginx"

validate: ## Проверить доступность сервисов по HTTP
	@echo "$(YELLOW)Проверка работы сервисов...$(NC)"
	@echo -n "Nginx (http://localhost:$(NGINX_PORT)): "
	@curl -s -o /dev/null -w "%{http_code}" http://localhost:$(NGINX_PORT) && echo " $(GREEN)✓$(NC)" || echo " $(RED)✗$(NC)"
	@echo -n "pgAdmin (http://localhost:8080): "
	@curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 && echo " $(GREEN)✓$(NC)" || echo " $(RED)✗$(NC)"
	@echo "$(YELLOW)Статус контейнеров:$(NC)"
	@$(COMPOSE) ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

clean: ## Удалить контейнеры и тома
	$(COMPOSE) down -v
	@echo "$(RED)! Контейнеры и данные БД удалены$(NC)"

clean-all: ## Полная очистка (контейнеры, образы, тома)
	@echo "$(YELLOW)Полная очистка...$(NC)"
	$(COMPOSE) down -v --rmi all
	@echo "$(GREEN)✓ Выполнена полная очистка$(NC)"

dev-reset: clean-all build up ## Сброс среды разработки
	@echo "$(GREEN)✓ Среда разработки сброшена и перезапущена!$(NC)"

clean-prod: ## Удалить prod контейнеры и тома
	$(COMPOSE_PROD) down -v
	@echo "$(RED)! Prod контейнеры и данные БД удалены$(NC)"

clean-all-prod: ## Полная очистка prod (контейнеры, образы, тома)
	@echo "$(YELLOW)Полная очистка prod...$(NC)"
	$(COMPOSE_PROD) down -v --rmi all
	@echo "$(GREEN)✓ Выполнена полная очистка prod$(NC)"

prod-reset: clean-all-prod rebuild-prod up-prod ## Сброс prod среды
	@echo "$(GREEN)✓ Prod среда сброшена и перезапущена!$(NC)"

.DEFAULT_GOAL := help
