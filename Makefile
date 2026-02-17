# ==========================================
# Laravel PHP-FPM Nginx Socket (Boilerplate)
# ==========================================

.PHONY: help up down restart build rebuild logs status shell-php shell-nginx shell-postgres clean setup artisan migrate laravel-install

# Цвета для вывода
YELLOW=\033[0;33m
GREEN=\033[0;32m
RED=\033[0;31m
NC=\033[0m

# Сервисы
PHP_CONTAINER=laravel-php-nginx-socket
NGINX_CONTAINER=laravel-nginx-socket
POSTGRES_CONTAINER=laravel-postgres-nginx-socket
PGADMIN_CONTAINER=laravel-pgadmin-nginx-socket

help: ## Показать справку
	@echo "$(YELLOW)Laravel Docker Boilerplate (Unix Socket)$(NC)"
	@echo "======================================"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "$(GREEN)%-20s$(NC) %s\n", $$1, $$2}'

check-files: ## Проверить наличие всех необходимых файлов
	@echo "$(YELLOW)Проверка файлов конфигурации...$(NC)"
	@test -f docker-compose.yml || (echo "$(RED)✗ docker-compose.yml не найден$(NC)" && exit 1)
	@test -f .env || (echo "$(RED)✗ .env не найден. Убедитесь, что вы настроили проект Laravel$(NC)" && exit 1)
	@test -f docker/php.Dockerfile || (echo "$(RED)✗ docker/php.Dockerfile не найден$(NC)" && exit 1)
	@test -f docker/nginx.Dockerfile || (echo "$(RED)✗ docker/nginx.Dockerfile не найден$(NC)" && exit 1)
	@test -f docker/nginx/conf.d/laravel.conf || (echo "$(RED)✗ config/nginx/conf.d/default.conf не найден$(NC)" && exit 1)
	@test -f docker/php/php.ini || (echo "$(RED)✗ config/php/php.ini не найден$(NC)" && exit 1)
	@test -f docker/php/www.conf || (echo "$(RED)✗ config/php/www.conf не найден$(NC)" && exit 1)
	@echo "$(GREEN)✓ Все файлы на месте$(NC)"

up: check-files ## Запустить контейнеры
	docker compose up -d
	@echo "$(GREEN)✓ Проект запущен на http://localhost$(NC)"

down: ## Остановить контейнеры
	docker compose down

restart: ## Перезапустить контейнеры
	docker compose restart

build: ## Собрать образы
	docker compose build

rebuild: ## Пересобрать образы без кэша
	docker compose build --no-cache

logs: ## Показать логи
	docker compose logs -f

logs-php: ## Просмотр логов PHP-FPM
	docker compose logs -f $(PHP_CONTAINER)

logs-nginx: ## Просмотр логов Nginx
	docker compose logs -f $(NGINX_CONTAINER)

logs-postgres: ## Просмотр логов PostgreSQL
	docker compose logs -f $(POSTGRES_CONTAINER)

logs-pgadmin: ## Просмотр логов pgAdmin
	docker compose logs -f $(PGADMIN_CONTAINER)

status: ## Статус контейнеров
	docker compose ps

shell-php: ## Войти в контейнер PHP
	docker compose exec $(PHP_CONTAINER) sh

shell-nginx: ## Подключиться к контейнеру Nginx
	docker compose exec $(NGINX_CONTAINER) sh

shell-postgres: ## Подключиться к PostgreSQL CLI
	@echo "$(YELLOW)Подключение к базе...$(NC)"
	@DB_USER=$$(grep '^DB_USERNAME=' .env | cut -d '=' -f 2- | tr -d '[:space:]'); \
	DB_NAME=$$(grep '^DB_DATABASE=' .env | cut -d '=' -f 2- | tr -d '[:space:]'); \
	docker compose exec $(POSTGRES_CONTAINER) psql -U $$DB_USER -d $$DB_NAME

# --- Команды Laravel ---
setup: ## Полная инициализация проекта с нуля
	@make build
	@make up
	@echo "$(YELLOW)Ожидание готовности базы данных...$(NC)"
	@docker compose exec $(POSTGRES_CONTAINER) sh -c 'until pg_isready; do sleep 1; done'
	@make install-deps
	@make artisan CMD="key:generate"
	@make migrate
	@make permissions
	@make cleanup-nginx
	@make npm-install
	@echo "$(GREEN)✓ Проект готов: http://localhost$(NC)"

install-deps: ## Установка всех зависимостей (Composer + NPM)
	@echo "$(YELLOW)Установка зависимостей...$(NC)"
	$(MAKE) composer-install
	$(MAKE) npm-install

# --- Команды Composer ---
composer-install: ## Установить зависимости через Composer
	docker compose exec $(PHP_CONTAINER) composer install

composer-update: ## Обновить зависимости через Composer
	docker compose exec $(PHP_CONTAINER) composer update

composer-require: ## Установить пакет через Composer (make composer-require PACKAGE=vendor/package)
	docker compose exec $(PHP_CONTAINER) composer require $(PACKAGE)

npm-install: ## Установить NPM зависимости
	docker compose exec $(PHP_CONTAINER) npm install

npm-dev: ## Запустить Vite в режиме разработки (hot reload)
	docker compose exec $(PHP_CONTAINER) npm run dev

npm-build: ## Собрать фронтенд для продакшена
	docker compose exec $(PHP_CONTAINER) npm run build

artisan: ## Запустить команду artisan (make artisan CMD="migrate")
	docker compose exec $(PHP_CONTAINER) php artisan $(CMD)

composer: ## Запустить команду composer (make composer CMD="install")
	docker compose exec $(PHP_CONTAINER) composer $(CMD)

migrate: ## Запустить миграции
	docker compose exec $(PHP_CONTAINER) php artisan migrate

rollback: ## Откатить миграции
	docker compose exec $(PHP_CONTAINER) php artisan migrate:rollback

fresh: ## Пересоздать базу и запустить сиды
	docker compose exec $(PHP_CONTAINER) php artisan migrate:fresh --seed

tinker: ## Запустить Laravel Tinker
	docker compose exec $(PHP_CONTAINER) php artisan tinker

test-php: ## Запустить тесты PHP (PHPUnit)
	docker compose exec $(PHP_CONTAINER) php artisan test

permissions: ## Исправить права доступа для Laravel (storage/cache)
	@echo "$(YELLOW)Исправление прав доступа...$(NC)"
	docker compose exec $(PHP_CONTAINER) sh -c "if [ -d storage ]; then chown -R www-data:www-data storage bootstrap/cache && chmod -R ug+rwX storage bootstrap/cache; fi"
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
	@echo "  • PHP-FPM 8.4 (Alpine)"
	@echo "  • Nginx"
	@echo "  • PostgreSQL 17"
	@echo "  • pgAdmin 4"
	@echo ""
	@echo "$(GREEN)Структура:$(NC)"
	@echo "  • docker/           - Dockerfiles и конфиги сервисов"
	@echo "  • .env              - единый файл настроек (Laravel + Docker)"
	@echo ""
	@echo "$(GREEN)Порты:$(NC)"
	@echo "  • 80   - Nginx (Web Server)"
	@echo "  • 5432 - PostgreSQL (Database)"
	@echo "  • 8080 - pgAdmin (DB Admin Interface)"
	@echo "  • Unix Socket - Связь PHP-FPM <-> Nginx"

validate: ## Проверить доступность сервисов по HTTP
	@echo "$(YELLOW)Проверка работы сервисов...$(NC)"
	@echo -n "Nginx (http://localhost): "
	@curl -s -o /dev/null -w "%{http_code}" http://localhost && echo " $(GREEN)✓$(NC)" || echo " $(RED)✗$(NC)"
	@echo -n "pgAdmin (http://localhost:8080): "
	@curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 && echo " $(GREEN)✓$(NC)" || echo " $(RED)✗$(NC)"
	@echo "$(YELLOW)Статус контейнеров:$(NC)"
	@docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"


clean: ## Удалить контейнеры и тома
	docker compose down -v
	@echo "$(RED)! Контейнеры и данные БД удалены$(NC)"

clean-all: ## Полная очистка (контейнеры, образы, тома)
	@echo "$(YELLOW)Полная очистка...$(NC)"
	docker compose down -v --rmi all
	@echo "$(GREEN)✓ Выполнена полная очистка$(NC)"

dev-reset: clean-all build up ## Сброс среды разработки
	@echo "$(GREEN)✓ Среда разработки сброшена и перезапущена!$(NC)"

.DEFAULT_GOAL := help
