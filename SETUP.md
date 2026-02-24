# Инструкция по работе с Laravel Boilerplate

Этот boilerplate предназначен для быстрого развертывания Laravel-проекта с архитектурой **PHP-FPM 8.5 + Nginx 1.27 (Unix socket) + PostgreSQL 18.2 + Redis 8.6**.

---

## Содержание

1. [Для каких приложений подходит](#для-каких-приложений-подходит)
2. [Структура проекта](#структура-проекта)
3. [Быстрый старт (Development)](#быстрый-старт-development)
4. [Работа с окружениями](#работа-с-окружениями)
5. [Команды Makefile](#команды-makefile)
6. [Тестирование](#тестирование)
7. [Production-деплой](#production-деплой)
8. [Архитектура Docker](#архитектура-docker)
9. [Конфигурация сервисов](#конфигурация-сервисов)
10. [SSL/TLS (HTTPS)](#ssltls-https)
11. [Troubleshooting](#troubleshooting)

---

## Для каких приложений подходит

### ✅ Blade-based приложения
Классический Laravel: Blade templates, server-side rendering, Tailwind/Bootstrap.
**Примеры:** CRM, админки, корпоративные сайты, SaaS-панели, internal tools.

### ✅ Laravel + Livewire / Inertia
Frontend внутри Laravel: Livewire, Inertia + Vue/React. JS живёт в `resources/`, Vite используется только для сборки.

### ✅ API-only backend
Laravel как REST / GraphQL API без UI. Один сервис, простая деплой-модель.

**Итог:** подходит для Blade, Livewire, Inertia, API-only, Admin panels, Small–medium SaaS.

---

## Структура проекта

```
├── docker/
│   ├── php.Dockerfile          # Multi-stage: php-base → frontend-build → production
│   ├── nginx.Dockerfile        # Nginx 1.27 Alpine
│   ├── php/
│   │   ├── php.ini             # PHP конфиг для разработки (display_errors = On)
│   │   ├── php.prod.ini        # PHP конфиг для production (display_errors = Off, OPCache max)
│   │   └── www.conf            # PHP-FPM pool (Unix socket, healthcheck ping)
│   └── nginx/
│       └── conf.d/
│           └── laravel.conf    # Nginx vhost (security headers, FastCGI буферы)
├── docker-compose.yml          # Базовые сервисы (PHP, Nginx, Postgres, Redis, Queue, Scheduler)
├── docker-compose.dev.yml      # Dev overlay (монтирование кода, HMR, pgAdmin, порты)
├── docker-compose.prod.yml     # Prod overlay (образы из registry, миграции)
├── docker-compose.test.yml     # Test overlay (изолированная БД, coverage)
├── .dockerignore               # Исключения из контекста сборки
├── .env.docker                 # Шаблон Docker-переменных для .env
├── Makefile                    # Автоматизация всех операций
├── gitlab-ci.yml               # CI/CD конфигурация
└── docs/                       # Документация и планы развития
```

---

## Быстрый старт (Development)

### Предварительные требования

- **Docker** ≥ 24.0 и **Docker Compose** ≥ 2.20
- **Git**

### Шаг 1. Создание Laravel-проекта

```bash
composer create-project laravel/laravel my-project
cd my-project
```

### Шаг 2. Копирование файлов boilerplate

Скопируйте в корень Laravel-проекта:
- Папку `docker/` (со всеми подпапками)
- Файлы `docker-compose.yml`, `docker-compose.dev.yml`, `docker-compose.prod.yml`, `docker-compose.test.yml`
- Файлы `Makefile`, `.dockerignore`, `.env.docker`

### Шаг 3. Настройка .env

Откройте `.env` и внесите изменения:

```dotenv
# --- Замените стандартные значения ---
DB_CONNECTION=pgsql
DB_HOST=laravel-postgres-nginx-socket
DB_PORT=5432
DB_DATABASE=laravel
DB_USERNAME=postgres
DB_PASSWORD=root

REDIS_HOST=laravel-redis-nginx-socket
REDIS_PORT=6379

QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
CACHE_STORE=redis

# --- Добавьте в конец файла (из .env.docker) ---
PGADMIN_DEFAULT_EMAIL=admin@example.com
PGADMIN_DEFAULT_PASSWORD=admin

NGINX_PORT=80
DB_FORWARD_PORT=5432
REDIS_FORWARD_PORT=6379
PGADMIN_PORT=8080

XDEBUG_MODE=off
XDEBUG_START=no
XDEBUG_CLIENT_HOST=host.docker.internal
```

### Шаг 4. Запуск

```bash
make setup
```

Эта команда автоматически:
1. Соберёт Docker-образы
2. Запустит все контейнеры (PHP-FPM, Nginx, PostgreSQL, Redis, Queue Worker, Scheduler, Node HMR, pgAdmin)
3. Установит зависимости (Composer + NPM)
4. Сгенерирует APP_KEY
5. Запустит миграции
6. Настроит права доступа

**Готово!** Проект доступен:
- 🌐 **Сайт:** http://localhost
- 🗄️ **pgAdmin:** http://localhost:8080
- 🔥 **Vite HMR:** http://localhost:5173

---

## Работа с окружениями

### Development (по умолчанию)

```bash
make up          # Запустить
make down        # Остановить
make restart     # Перезапустить
make logs        # Логи всех сервисов
```

Особенности dev-режима:
- Код монтируется из хоста (изменения применяются мгновенно)
- Vite HMR для горячей перезагрузки фронтенда
- pgAdmin для управления БД
- Порты PostgreSQL и Redis проброшены наружу для IDE/GUI-клиентов
- Xdebug доступен через `.env` (`XDEBUG_MODE=debug`)
- `php.ini` с `display_errors = On`

### Production

```bash
make up-prod     # Запустить из registry-образов
```

Особенности prod-режима:
- Иммутабельные образы из Docker Registry (CI/CD собирает)
- `php.prod.ini`: `display_errors = Off`, OPCache без проверки timestamps, JIT
- `composer install --no-dev --optimize-autoloader` внутри образа
- Автоматические миграции при деплое (сервис `migrate`)
- Queue Worker и Scheduler работают из тех же образов
- Graceful shutdown (`STOPSIGNAL SIGQUIT`)
- Процесс PHP-FPM запускается от `www-data` (non-root)

### Testing (CI)

```bash
make test-ci     # Полный цикл: поднять окружение → миграции → тесты → очистка
make test-php    # Тесты в текущем dev-окружении
make test-coverage  # Тесты с покрытием кода (Xdebug coverage)
```

Особенности test-режима:
- Изолированная БД `laravel_test`
- Queue и Scheduler отключены (profiles: disabled)
- Xdebug в режиме `coverage`

---

## Команды Makefile

### Управление контейнерами

| Команда | Описание |
|---------|----------|
| `make up` | Запустить проект (dev) |
| `make up-prod` | Запустить проект (prod) |
| `make down` | Остановить контейнеры |
| `make restart` | Перезапустить контейнеры |
| `make build` | Собрать образы |
| `make rebuild` | Пересобрать без кэша |
| `make status` | Статус контейнеров |
| `make clean` | Удалить контейнеры и тома |
| `make clean-all` | Полная очистка (+ образы) |
| `make dev-reset` | Сброс среды разработки |

### Логи

| Команда | Описание |
|---------|----------|
| `make logs` | Все сервисы |
| `make logs-php` | PHP-FPM |
| `make logs-nginx` | Nginx |
| `make logs-postgres` | PostgreSQL |
| `make logs-redis` | Redis |
| `make logs-queue` | Queue Worker |
| `make logs-scheduler` | Scheduler |
| `make logs-node` | Node (HMR) |
| `make logs-pgadmin` | pgAdmin |

### Shell-доступ

| Команда | Описание |
|---------|----------|
| `make shell-php` | Консоль PHP-контейнера |
| `make shell-nginx` | Консоль Nginx |
| `make shell-node` | Консоль Node |
| `make shell-postgres` | PostgreSQL CLI (psql) |
| `make shell-redis` | Redis CLI |

### Laravel

| Команда | Описание |
|---------|----------|
| `make artisan CMD="..."` | Любая artisan-команда |
| `make migrate` | Запустить миграции |
| `make rollback` | Откатить миграции |
| `make fresh` | Пересоздать БД + сиды |
| `make tinker` | Laravel Tinker |
| `make test-php` | PHPUnit тесты |
| `make test-ci` | Тесты в CI-окружении |
| `make test-coverage` | Тесты с покрытием |

### Зависимости

| Команда | Описание |
|---------|----------|
| `make composer-install` | `composer install` |
| `make composer-update` | `composer update` |
| `make composer-require PACKAGE=vendor/pkg` | `composer require` |
| `make npm-install` | `npm install` |
| `make npm-dev` | Vite dev server |
| `make npm-build` | Сборка фронтенда |

---

## Тестирование

### Локальные тесты (в dev-окружении)

```bash
make test-php
```

### CI-тесты (изолированное окружение)

```bash
make test-ci
```

Поднимает отдельное окружение с тестовой БД, запускает миграции и тесты, затем удаляет всё.

### Покрытие кода

```bash
make test-coverage
```

Требует Xdebug. В `docker-compose.test.yml` уже настроен `XDEBUG_MODE=coverage`.

### Настройка phpunit.xml

Для корректной работы в Docker добавьте в `phpunit.xml`:

```xml
<php>
    <env name="DB_CONNECTION" value="pgsql"/>
    <env name="DB_HOST" value="laravel-postgres-nginx-socket"/>
    <env name="DB_DATABASE" value="laravel_test"/>
    <env name="DB_USERNAME" value="postgres"/>
    <env name="DB_PASSWORD" value="testing"/>
</php>
```

---

## Production-деплой

### Сборка production-образа

```bash
# Сборка PHP-образа (включает composer install, фронтенд-ассеты, prod php.ini)
docker build -f docker/php.Dockerfile --target production -t myapp/php:latest ./

# Сборка Nginx-образа
docker build -f docker/nginx.Dockerfile -t myapp/nginx:latest ./docker
```

### Что включает production-образ

1. **php.prod.ini** — `display_errors = Off`, OPCache без проверки timestamps, JIT включён
2. **composer install --no-dev** — только production-зависимости с оптимизированным автозагрузчиком
3. **Собранные фронтенд-ассеты** — из multi-stage сборки Node.js
4. **STOPSIGNAL SIGQUIT** — корректное завершение обработки запросов
5. **USER www-data** — запуск от непривилегированного пользователя
6. **Кеширование Laravel** — config, routes, views очищены для пересборки при старте

### Деплой через Docker Compose

```bash
# На сервере
export CI_REGISTRY_IMAGE=registry.example.com/myapp
export IMAGE_TAG=v1.0.0

docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

Сервис `migrate` автоматически выполнит миграции при старте.

### CI/CD (GitLab)

Файл `gitlab-ci.yml` подключает шаблон из внутреннего репозитория. Настройте переменные в GitLab CI/CD Settings:

- `CI_REGISTRY_IMAGE` — адрес Docker Registry
- `IMAGE_TAG` — тег образа (обычно `$CI_COMMIT_SHORT_SHA` или `$CI_COMMIT_TAG`)

---

## Архитектура Docker

### Схема взаимодействия

```
                    ┌─────────────┐
                    │   Client    │
                    └──────┬──────┘
                           │ :80
                    ┌──────▼──────┐
                    │    Nginx    │
                    │  (1.27-alp) │
                    └──────┬──────┘
                           │ Unix Socket
                    ┌──────▼──────┐
                    │   PHP-FPM   │──────────┐
                    │  (8.5-alp)  │          │
                    └──────┬──────┘          │
                           │                 │
              ┌────────────┼────────────┐    │
              │            │            │    │
       ┌──────▼──────┐ ┌──▼───┐ ┌──────▼────▼─┐
       │  PostgreSQL  │ │Redis │ │ Queue Worker │
       │   (18.2)     │ │(8.6) │ │ + Scheduler  │
       └─────────────┘ └──────┘ └──────────────┘
```

### Compose overlay-стратегия

- **docker-compose.yml** — базовые сервисы (всегда используется)
- **docker-compose.dev.yml** — dev: монтирование кода, HMR, pgAdmin, порты
- **docker-compose.prod.yml** — prod: registry-образы, миграции
- **docker-compose.test.yml** — test: изолированная БД, coverage

Запуск: `docker compose -f docker-compose.yml -f docker-compose.<env>.yml up -d`

### Multi-stage Dockerfile

```
frontend-build  →  Node.js: npm ci + npm run build
php-base        →  PHP-FPM + расширения + Composer (dev/prod база)
production      →  php-base + код + vendor + ассеты + prod php.ini
```

---

## Конфигурация сервисов

### PHP-FPM (`docker/php/www.conf`)

- Unix socket: `/var/run/php/php-fpm.sock`
- Process manager: `dynamic` (min 2, max 10)
- Healthcheck endpoint: `/ping` → `pong`
- Slowlog включён для диагностики
- `pm.max_requests = 500` — защита от утечек памяти

### Nginx (`docker/nginx/conf.d/laravel.conf`)

- Security headers: `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, `Referrer-Policy`, `Permissions-Policy`
- `server_tokens off` — скрыта версия Nginx
- Защита от доступа к `.env`, `.git` и другим скрытым файлам
- FastCGI буферы настроены для больших ответов
- `client_max_body_size 20M`

### PHP конфигурация

| Параметр | Development | Production |
|----------|-------------|------------|
| `display_errors` | On | Off |
| `display_startup_errors` | On | Off |
| `opcache.validate_timestamps` | 1 | 0 |
| `opcache.jit` | — | 1255 |
| `opcache.jit_buffer_size` | — | 128M |
| `max_execution_time` | 60 | 30 |
| `error_reporting` | E_ALL | E_ALL & ~E_DEPRECATED & ~E_STRICT |
| Xdebug | Доступен через ENV | Не устанавливается |

### Логирование

Все сервисы используют Docker `json-file` драйвер с ротацией:
- Максимальный размер файла: **10 MB**
- Максимальное количество файлов: **3**

---

## SSL/TLS (HTTPS)

В production HTTPS обычно терминируется на уровне reverse proxy / load balancer (Traefik, Caddy, облачный LB) **перед** этим стеком. Nginx в контейнере слушает порт 80 (HTTP).

Если нужен HTTPS напрямую:

1. Добавьте сертификаты в volume или секреты
2. Обновите `laravel.conf`:
   ```nginx
   listen 443 ssl;
   ssl_certificate /etc/nginx/ssl/cert.pem;
   ssl_certificate_key /etc/nginx/ssl/key.pem;
   ```
3. Пробросьте порт 443 в `docker-compose.prod.yml`

---

## Troubleshooting

### Контейнер PHP не стартует

```bash
make logs-php
# Проверьте: правильно ли настроен .env, есть ли vendor/ (для dev: make composer-install)
```

### Ошибка "Connection refused" к БД

Убедитесь, что `DB_HOST` в `.env` совпадает с именем сервиса в `docker-compose.yml`:
```dotenv
DB_HOST=laravel-postgres-nginx-socket
```

### Права доступа (storage/cache)

```bash
make permissions
```

### Xdebug не работает

1. Пересоберите образ с Xdebug:
   ```bash
   COMPOSE_DEV_ARGS="--build-arg INSTALL_XDEBUG=true" make rebuild
   ```
   Или добавьте в `docker-compose.dev.yml` в секцию `build.args`:
   ```yaml
   args:
     INSTALL_XDEBUG: "true"
   ```
2. Настройте `.env`:
   ```dotenv
   XDEBUG_MODE=debug
   XDEBUG_START=yes
   ```
3. Перезапустите: `make restart`

### Queue Worker не обрабатывает задачи

```bash
make logs-queue
# Убедитесь, что QUEUE_CONNECTION=redis в .env
# Перезапустите: make restart
```

### Полный сброс окружения

```bash
make dev-reset   # Удалит всё (контейнеры, образы, тома) и пересоберёт
```
