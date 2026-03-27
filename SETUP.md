# Инструкция по работе с Laravel Boilerplate

Этот boilerplate предназначен для быстрого развертывания Laravel-проекта с архитектурой **PHP-FPM 8.5 + Nginx 1.29 (Unix Socket) + PostgreSQL 18.2 + Redis 8.6**.

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

```text
├── docker/
│   ├── php.Dockerfile            # Multi-stage: php-base → frontend-build → production
│   ├── nginx.Dockerfile          # Nginx 1.29 Alpine
│   ├── php/
│   │   ├── php.ini               # PHP конфиг для разработки (display_errors = On)
│   │   ├── php.prod.ini          # PHP конфиг для production (display_errors = Off, OPCache max)
│   │   └── www.conf              # PHP-FPM pool (Unix Socket, healthcheck ping)
│   └── nginx/
│       └── conf.d/
│           └── laravel.conf      # Nginx vhost (security headers, FastCGI buffers)
├── docker-compose.yml            # Базовая конфигурация сервисов и разработка
├── docker-compose.prod.yml       # Прод-конфигурация сервисов
├── docker-compose.prod.local.yml # Prod: локальный запуск (сборка из Dockerfile)
├── .dockerignore                 # Исключения из контекста сборки
├── .env.docker                   # Шаблон Docker-переменных для .env
├── .env.production.example       # Пример production-переменных
├── Makefile                      # Автоматизация всех операций
└── README.md / SETUP.md          # Основная документация по проекту
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
- Файлы `docker-compose.yml`, `docker-compose.prod.yml`, `docker-compose.prod.local.yml`
- Файлы `Makefile`, `.dockerignore`, `.env.docker`, `.env.production.example`

### Шаг 3. Настройка конфигурационных файлов Laravel

#### Удаление лишних файлов

Laravel по умолчанию создаёт `database/database.sqlite`. В этом стеке используется PostgreSQL, поэтому удалите файл и добавьте маску в `.gitignore`:

```bash
rm database/database.sqlite
```

Добавьте в `.gitignore`:

```text
database/*.sqlite
```

#### Обновление fallback-значений конфигурации

Laravel хранит дефолтные значения подключений в `config/`. По умолчанию они указывают на `sqlite` и `database`. Для корректной работы в случае проблем с `.env` замените их на значения, соответствующие этому стеку:

**`config/database.php`**
```php
'default' => env('DB_CONNECTION', 'pgsql'),
```

**`config/queue.php`**
```php
'default' => env('QUEUE_CONNECTION', 'redis'),
// ...
'batching' => [
    'database' => env('DB_CONNECTION', 'pgsql'),
],
'failed' => [
    'database' => env('DB_CONNECTION', 'pgsql'),
],
```

**`config/cache.php`**
```php
'default' => env('CACHE_STORE', 'redis'),
```

**`config/session.php`**
```php
'driver' => env('SESSION_DRIVER', 'redis'),
```

> **Примечание:** Миграция `create_cache_table` создаёт таблицу `cache` в БД, но при `CACHE_STORE=redis` она не используется. Её можно удалить для чистоты или оставить как fallback.

---

### Шаг 4. Настройка .env

Откройте `.env` и внесите изменения:

```dotenv
# --- Замените стандартные значения ---
DB_CONNECTION=pgsql
DB_HOST=laravel-postgres-nginx-uds
DB_PORT=5432
DB_DATABASE=laravel
DB_USERNAME=postgres
DB_PASSWORD=password

REDIS_HOST=laravel-redis-nginx-uds
REDIS_PORT=6379

QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
CACHE_STORE=redis

# --- Добавьте в конец файла (из .env.docker) ---
PGADMIN_DEFAULT_EMAIL=admin@example.com
PGADMIN_DEFAULT_PASSWORD=admin

NGINX_PORT=8050
DB_FORWARD_PORT=5432
REDIS_FORWARD_PORT=6379
PGADMIN_PORT=8080

XDEBUG_MODE=off
XDEBUG_START=no
XDEBUG_CLIENT_HOST=host.docker.internal
```

### Шаг 5. Запуск

```bash
make setup
```

Эта команда автоматически:
1. Соберёт Docker-образы
2. Запустит все контейнеры (PHP-FPM, Nginx, PostgreSQL, Redis, Queue Worker, Scheduler, Node HMR, pgAdmin)
3. Установит зависимости (Composer + NPM)
4. Сгенерирует `APP_KEY`
5. Запустит миграции
6. Настроит права доступа
7. Удалит `public/.htaccess`, так как маршрутизация уже настроена в `laravel.conf`

**Готово!** Проект доступен:
- **Сайт:** http://localhost:8050
- **pgAdmin:** http://localhost:8080
- **Vite HMR:** http://localhost:5173

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
- Xdebug установлен в dev-образе и включается через `.env`
- `php.ini` с `display_errors = On`

### Production

```bash
cp .env.production.example .env.production
make up-prod
```

Особенности prod-режима:
- Локальный production-запуск через `docker-compose.prod.local.yml`
- `php.prod.ini`: `display_errors = Off`, OPCache без проверки timestamps, JIT отключён
- `composer install --no-dev --optimize-autoloader` внутри образа
- Автоматические миграции выполняются при старте PHP-контейнера
- Queue Worker и Scheduler работают из тех же образов
- Graceful shutdown (`STOPSIGNAL SIGQUIT`)
- Процесс PHP-FPM запускается от `www-data`

---

## Команды Makefile

### Управление контейнерами

| Команда | Описание |
|---------|----------|
| `make up` | Запустить проект (dev) |
| `make up-prod` | Запустить проект (prod) |
| `make down` | Остановить dev-контейнеры |
| `make down-prod` | Остановить prod-контейнеры |
| `make restart` | Перезапустить контейнеры |
| `make build` | Собрать образы |
| `make rebuild` | Пересобрать dev-образы без кэша |
| `make rebuild-prod` | Пересобрать prod-образы без кэша |
| `make status` | Статус контейнеров |
| `make clean` | Удалить контейнеры и тома |
| `make clean-all` | Полная очистка dev (+ образы) |
| `make dev-reset` | Сброс среды разработки |
| `make clean-prod` | Удалить prod-контейнеры и тома |
| `make clean-all-prod` | Полная очистка prod (+ образы) |
| `make prod-reset` | Сброс prod-среды |

### Логи

| Команда | Описание |
|---------|----------|
| `make logs` | Все dev-сервисы |
| `make logs-prod` | Все prod-сервисы |
| `make logs-php` | PHP-FPM |
| `make logs-php-prod` | PHP-FPM (prod) |
| `make logs-nginx` | Nginx |
| `make logs-nginx-prod` | Nginx (prod) |
| `make logs-postgres` | PostgreSQL |
| `make logs-postgres-prod` | PostgreSQL (prod) |
| `make logs-redis` | Redis |
| `make logs-redis-prod` | Redis (prod) |
| `make logs-queue` | Queue Worker |
| `make logs-queue-prod` | Queue Worker (prod) |
| `make logs-scheduler` | Scheduler |
| `make logs-scheduler-prod` | Scheduler (prod) |
| `make logs-node` | Node (HMR) |
| `make logs-pgadmin` | pgAdmin |

### Shell-доступ

| Команда | Описание |
|---------|----------|
| `make shell-php` | Консоль PHP-контейнера |
| `make shell-php-prod` | Консоль PHP-контейнера (prod) |
| `make shell-nginx` | Консоль Nginx |
| `make shell-nginx-prod` | Консоль Nginx (prod) |
| `make shell-node` | Консоль Node |
| `make shell-postgres` | PostgreSQL CLI (`psql`) |
| `make shell-postgres-prod` | PostgreSQL CLI (`psql`) для prod |
| `make shell-redis` | Redis CLI / ping |
| `make shell-redis-prod` | Redis CLI / ping для prod |
| `make shell-queue` | Консоль Queue Worker |
| `make shell-queue-prod` | Консоль Queue Worker (prod) |
| `make shell-scheduler` | Консоль Scheduler |
| `make shell-scheduler-prod` | Консоль Scheduler (prod) |

### Laravel и зависимости

| Команда | Описание |
|---------|----------|
| `make setup` | Полная инициализация проекта |
| `make install-deps` | Установить Composer + NPM зависимости |
| `make artisan CMD="..."` | Любая artisan-команда |
| `make composer CMD="..."` | Любая composer-команда |
| `make composer-install` | `composer install` |
| `make composer-update` | `composer update` |
| `make composer-require PACKAGE=vendor/pkg` | `composer require` |
| `make migrate` | Запустить миграции |
| `make rollback` | Откатить миграции |
| `make fresh` | Пересоздать БД + сиды |
| `make tinker` | Laravel Tinker |
| `make test-php` | PHP-тесты |
| `make test-coverage` | Тесты с покрытием |
| `make npm-install` | `npm install` |
| `make npm-dev` | Vite dev server |
| `make npm-build` | Production-сборка фронтенда |
| `make permissions` | Исправить права `storage` и `bootstrap/cache` |
| `make cleanup-nginx` | Удалить `public/.htaccess` |
| `make info` | Показать информацию о проекте |
| `make validate` | Проверить HTTP-доступность сервисов |

---

## Тестирование

```bash
make test-php
make test-coverage
```

Особенности тестирования:
- По умолчанию используется основная БД, если иное не настроено в `phpunit.xml`
- Для покрытия используется Xdebug

---

## Production-деплой

Минимальная последовательность для локальной проверки production-режима:

```bash
cp .env.production.example .env.production
make up-prod
make logs-prod
```

Что важно проверить перед деплоем:
- Актуальные значения `APP_URL`, `APP_KEY`, `DB_*`, `REDIS_*` в `.env.production`
- Настройки внешнего reverse proxy / TLS-терминации, если HTTPS завершается вне контейнера
- Доступность постоянных томов для PostgreSQL и Redis
- Политику перезапуска и мониторинг контейнеров

---

## Архитектура Docker

### Схема взаимодействия

```text
                    ┌─────────────┐
                    │   Client    │
                    └──────┬──────┘
                           │ :80 / :8050
                    ┌──────▼──────┐
                    │    Nginx    │
                    │   (Alpine)  │
                    └──────┬──────┘
                           │ Unix Socket
                    ┌──────▼──────┐
                    │   PHP-FPM   │──────────┐
                    │ (8.5 Alpine)│          │
                    └──────┬──────┘          │
                           │                 │
                 ┌─────────▼─────────┐ ┌────▼─────┐
                 │   PostgreSQL 18   │ │ Redis 8.6│
                 └───────────────────┘ └──────────┘
```

### Ключевая идея

Nginx выступает как frontend web server и проксирует PHP-запросы в PHP-FPM через Unix Socket (`/var/run/php/php-fpm.sock`). Это даёт ту же контейнерную изоляцию, но без накладных расходов TCP внутри связки Nginx ↔ PHP-FPM.

---

## Конфигурация сервисов

### PHP-FPM
- Базовый runtime Laravel-приложения
- В dev-режиме монтирует код проекта
- В prod-режиме собирается как финальный immutable image

### Nginx
- Обслуживает публичные ассеты
- Проксирует PHP через FastCGI
- Использует конфигурацию из `docker/nginx/conf.d/laravel.conf`

### PostgreSQL
- Основная реляционная БД
- В dev-режиме проброшена на `DB_FORWARD_PORT`

### Redis
- Кэш, очереди, сессии
- В dev-режиме проброшен на `REDIS_FORWARD_PORT`

### Node
- Нужен только в development для Vite HMR

### Queue Worker / Scheduler
- Отдельные сервисы для фоновых задач Laravel
- Запускаются как отдельные процессы в Docker Compose

### pgAdmin
- Доступен только в dev-окружении
- Используется для администрирования PostgreSQL через браузер

---

## SSL/TLS (HTTPS)

По умолчанию boilerplate рассчитан на локальную работу по HTTP. Для production HTTPS обычно завершается:
- либо на внешнем reverse proxy / ingress,
- либо на балансировщике перед контейнерами.

Если TLS нужен внутри контейнерного контура, настройте отдельный frontend proxy или адаптируйте `laravel.conf` под SSL-виртуальный хост и сертификаты.

---

## Troubleshooting

### Сайт не открывается
- Проверьте `make status`
- Проверьте `make logs-nginx`
- Убедитесь, что порт `NGINX_PORT` свободен

### Laravel не подключается к БД
- Проверьте `DB_HOST=laravel-postgres-nginx-uds`
- Проверьте `make logs-postgres`
- Убедитесь, что в `.env` выбран `DB_CONNECTION=pgsql`

### Redis недоступен
- Проверьте `REDIS_HOST=laravel-redis-nginx-uds`
- Проверьте `make logs-redis`
- Если задан пароль, убедитесь, что он совпадает в `.env` и compose

### Vite HMR не работает
- Проверьте `make logs-node`
- Убедитесь, что порт `5173` свободен
- Проверьте, что frontend использует Vite и зависимости установлены

### Ошибки прав доступа
- Выполните:

```bash
make permissions
```

### Остался `public/.htaccess`
- Выполните:

```bash
make cleanup-nginx
```
