

# Технический отчёт: аудит Laravel Docker Boilerplate

## Метаданные отчёта

| Параметр | Значение |
|---|---|
| **Проект** | `laravel-nginx-sock-internal` |
| **Дата аудита** | 2026-02-23 |
| **Итоговая оценка** | **7.5 / 10** |
| **Назначение отчёта** | Передача AI-агенту для последовательной доработки |
| **Стек** | PHP 8.5 FPM + Nginx 1.27 (Unix socket) + PostgreSQL 18.2 + Redis 8.6 + Node 24 (Vite HMR) |
| **CI/CD** | GitLab CI (include из `ansible-laravel-internal`) |
| **Окружения** | dev / prod / test (compose overlay) |

---

## 1. Текущее состояние проекта (контекст для агента)

### Структура проекта
```
laravel-nginx-sock-internal/
├── docker/
│   ├── php.Dockerfile          # Multi-stage: frontend-build → php-base → production
│   ├── nginx.Dockerfile        # Nginx 1.27-alpine, конфиг запечатан внутрь
│   ├── php/
│   │   ├── php.ini             # Dev-конфиг (display_errors=On, OPCache validate)
│   │   ├── php.prod.ini        # Prod-конфиг (display_errors=Off, JIT, OPCache immutable)
│   │   └── www.conf            # FPM pool: unix socket, dynamic pm, healthcheck ping
│   └── nginx/conf.d/
│       └── laravel.conf        # Vhost: security headers, FastCGI, dotfile protection
├── docker-compose.yml          # Base: PHP + Nginx + Postgres + Redis + Queue + Scheduler
├── docker-compose.dev.yml      # Dev overlay: bind-mount, HMR, pgAdmin, проброс портов
├── docker-compose.prod.yml     # Prod overlay: registry images, env_file, migrate job
├── docker-compose.test.yml     # Test overlay: изолированная БД, coverage, disabled queue/scheduler
├── .dockerignore               # Исключения из build context
├── .env.docker                 # Шаблон Docker-переменных
├── Makefile                    # 40+ команд автоматизации
├── gitlab-ci.yml               # CI/CD include
├── docs/                       # Планы развития (cicd-plan, boilerplate-plan, migration-steps)
├── README.md
├── SETUP.md
└── production-level-setup.md   # Предыдущий самоаудит
```


### Что уже сделано хорошо (не трогать)
- Unix socket PHP-FPM ↔ Nginx (правильная архитектура)
- Multi-stage Dockerfile с targets `php-base` / `production`
- Overlay compose-стратегия (base / dev / prod / test)
- Отдельные `php.ini` и `php.prod.ini` с корректными настройками
- Healthcheck на всех сервисах (FPM ping, pg_isready, redis-cli ping)
- Xdebug через `ARG INSTALL_XDEBUG=false` (не попадает в prod)
- Queue worker + Scheduler в base compose
- Migrate one-off job в prod compose
- Log rotation (`json-file`, `max-size: 10m`, `max-file: 3`)
- `STOPSIGNAL SIGQUIT` + `USER www-data` в production stage
- `composer install --no-dev --optimize-autoloader` в production stage
- Подробная документация и Makefile

### Контекст: это boilerplate БЕЗ Laravel
Laravel не установлен. Порядок использования: `composer create-project laravel/laravel my-project` → скопировать файлы boilerplate → `make setup`. `.env.example` появится от Laravel.

### Контекст: Redis без пароля — осознанное решение
Redis работает во внутренней Docker-сети, без публикации портов в prod, используется только одним приложением. Пароль не требуется.

### Контекст: Postgres volume path `/var/lib/postgresql`
Postgres 18+ требует именно такой путь (без `/data`). Это корректно.

---

## 2. Список задач для доработки

Каждая задача содержит: приоритет, описание проблемы, затронутые файлы, конкретное техническое решение и критерий приёмки.

---

### ЗАДАЧА 1 — [HIGH] Gzip-компрессия в Nginx

**Проблема:** Nginx не сжимает ответы. При 1000+ пользователях это значительно увеличивает трафик и время загрузки страниц. Типичная экономия — 60-80% на текстовых ресурсах.

**Файл:** `docker/nginx/conf.d/laravel.conf`

**Что сделать:** Добавить блок gzip-компрессии внутри блока `server { }`, после security headers и перед `location / { }`:

```
# --------------------------------------------------------------------------
    # Сжатие ответов (Gzip)
    # --------------------------------------------------------------------------
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1000;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml
        application/xml+rss
        application/atom+xml
        image/svg+xml;
```


**Критерий приёмки:** `curl -H "Accept-Encoding: gzip" -sI http://localhost/ | grep -i content-encoding` возвращает `gzip`.

---

### ЗАДАЧА 2 — [HIGH] Кеширование статических ресурсов в Nginx

**Проблема:** Браузеры не кешируют CSS/JS/изображения — каждый запрос идёт на сервер. При 1000+ пользователях это лишняя нагрузка на Nginx и трафик.

**Файл:** `docker/nginx/conf.d/laravel.conf`

**Что сделать:** Добавить location-блок для статики. Разместить **перед** блоком `location ~ \.php$`:

```
# --------------------------------------------------------------------------
    # Кеширование статических ресурсов
    # --------------------------------------------------------------------------
    # Vite генерирует файлы с хешем в имени (immutable), поэтому
    # можно безопасно ставить длинный Cache-Control.
    location ~* \.(css|js|ico|gif|jpe?g|png|webp|avif|svg|woff2?|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
        try_files $uri =404;
    }
```


**Критерий приёмки:** `curl -sI http://localhost/build/assets/app-xxx.js | grep -i cache-control` возвращает `public, immutable` и `expires` в будущем.

---

### ЗАДАЧА 3 — [HIGH] Rate-limiting в Nginx

**Проблема:** Нет защиты от брутфорса и простейших DDoS-атак. При 1000+ пользователях один бот может исчерпать FPM-воркеры.

**Файл:** `docker/nginx/conf.d/laravel.conf`

**Что сделать:**

1. Добавить **перед** блоком `server { }` (на уровне `http`, но в данном случае Nginx подключает этот файл внутри `http`, так что ставим в начало файла, перед `server {`):

```
# --------------------------------------------------------------------------
# Rate Limiting — защита от брутфорса и DDoS
# --------------------------------------------------------------------------
# Общая зона: 30 запросов/сек на один IP
limit_req_zone $binary_remote_addr zone=general:10m rate=30r/s;

# Более строгая зона для login/api auth: 5 запросов/сек
limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/s;
```


2. Внутри `location / { }` добавить:

```
location / {
        limit_req zone=general burst=60 nodelay;
        try_files $uri $uri/ /index.php?$query_string;
    }
```


3. Добавить отдельный location для auth-эндпоинтов (после `location / { }`):

```
# Rate-limit для аутентификации (защита от брутфорса)
    location ~ ^/(login|register|forgot-password|reset-password) {
        limit_req zone=auth burst=10 nodelay;
        try_files $uri $uri/ /index.php?$query_string;
    }
```


**Критерий приёмки:** Массовые запросы с одного IP к `/login` получают HTTP 429 (или 503) после превышения лимита.

---

### ЗАДАЧА 4 — [HIGH] Production FPM pool конфигурация

**Проблема:** `pm.max_children = 10` — недостаточно для 1000+ одновременных пользователей. При `memory_limit = 256M`, каждый воркер потребляет ~50-100MB реально, 10 воркеров — это ~10 одновременных запросов к PHP. Остальные ждут в очереди.

**Файлы:** Создать новый файл `docker/php/www.prod.conf`, модифицировать `docker/php.Dockerfile`

**Что сделать:**

1. Создать файл `docker/php/www.prod.conf` — копию `www.conf` со следующими изменениями в секции Process Manager:

```ini
; ------------------------------------------------------------------------------
; Управление процессами (Process Manager) — PRODUCTION
; ------------------------------------------------------------------------------
pm = dynamic
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 1000
```


2. В `docker/php.Dockerfile`, в stage `production`, после строки `COPY ./php/php.prod.ini /usr/local/etc/php/conf.d/local.ini` добавить замену FPM-конфига:

```dockerfile
# Production FPM pool (больше воркеров для нагрузки)
RUN rm -f /usr/local/etc/php-fpm.d/www.conf
COPY ./php/www.prod.conf /usr/local/etc/php-fpm.d/www.conf
```


**Критерий приёмки:** `docker compose -f docker-compose.yml -f docker-compose.prod.yml exec laravel-php-nginx-socket php-fpm -tt 2>&1 | grep "pm.max_children"` показывает `50`.

---

### ЗАДАЧА 5 — [MEDIUM] Nginx healthcheck — проверка реальной работоспособности

**Проблема:** Текущий healthcheck Nginx (`nginx -t`) проверяет только валидность синтаксиса конфига, а не реальную доступность приложения. Если PHP-FPM зависнет или Laravel сломается — Nginx healthcheck останется зелёным.

**Файл:** `docker-compose.yml`

**Что сделать:** Заменить healthcheck сервиса `laravel-nginx-socket`:

```yaml
healthcheck:
      test: [ "CMD-SHELL", "wget -qO- http://localhost/ > /dev/null 2>&1 || exit 1" ]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 30s
```


**Примечание:** Когда в проекте будет установлен Laravel 11+, рекомендуется использовать встроенный endpoint `/up`:
```yaml
test: [ "CMD-SHELL", "wget -qO- http://localhost/up > /dev/null 2>&1 || exit 1" ]
```


**Критерий приёмки:** `docker inspect laravel-nginx-socket --format='{{.State.Health.Status}}'` возвращает `healthy` только когда приложение реально отвечает.

---

### ЗАДАЧА 6 — [MEDIUM] Добавить `network` для queue, scheduler и migrate в prod overlay

**Проблема:** В `docker-compose.prod.yml` сервис `migrate` объявляет `networks: - laravel-nginx-socket-network`, но сервисы `laravel-queue-nginx-socket` и `laravel-scheduler-nginx-socket` не имеют `networks` в prod overlay. Они наследуют сеть из base compose, но при prod overlay `env_file` добавлен, а сеть для `migrate` указана явно — для консистентности стоит убедиться, что migrate также наследует сеть из base, а не переопределяет.

**Файл:** `docker-compose.prod.yml`

**Что сделать:** Удалить явное указание `networks` у `migrate` (он унаследует сеть из base compose), либо добавить `networks` ко всем сервисам для консистентности. Рекомендуется первый вариант — убрать у `migrate`:

```yaml
migrate:
    image: "${CI_REGISTRY_IMAGE}/php:${IMAGE_TAG}"
    restart: "no"
    working_dir: /var/www/laravel
    env_file:
      - .env
    command: [ "sh", "-lc", "php artisan migrate --force" ]
    depends_on:
      laravel-postgres-nginx-socket:
        condition: service_healthy
```


**Критерий приёмки:** `docker compose -f docker-compose.yml -f docker-compose.prod.yml config | grep -A5 migrate` — сервис подключён к `laravel-nginx-socket-network` через наследование base.

---

### ЗАДАЧА 7 — [MEDIUM] Content-Security-Policy header

**Проблема:** `X-XSS-Protection: 1; mode=block` — deprecated и игнорируется современными браузерами. Реальная защита от XSS обеспечивается CSP. Текущий набор security headers неполон.

**Файл:** `docker/nginx/conf.d/laravel.conf`

**Что сделать:** Заменить строку `add_header X-XSS-Protection` на базовый CSP. Оставить `X-XSS-Protection` для старых браузеров, но добавить CSP:

```
# --------------------------------------------------------------------------
    # Security Headers — защита от распространённых атак
    # --------------------------------------------------------------------------
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "0" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    # CSP: базовая политика, адаптировать под конкретный проект
    # Vite dev-server (localhost:5173) добавлять только в dev-конфиге
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self';" always;
```


**Примечание:** `unsafe-inline` и `unsafe-eval` для `script-src` — компромисс для Blade/Livewire/Inertia. При использовании nonce-based CSP от Laravel можно ужесточить.

**Критерий приёмки:** `curl -sI http://localhost/ | grep -i content-security-policy` возвращает CSP-заголовок.

---

### ЗАДАЧА 8 — [MEDIUM] Защита build context от утечки `.env` в production образ

**Проблема:** В `docker/php.Dockerfile`, stage `production` использует `COPY ../ ./` — это копирует весь корень проекта в образ. Build context для PHP Dockerfile = `./docker` (из compose), но `COPY ../` выходит за его пределы на уровень корня проекта. Файл `.dockerignore` лежит в корне проекта, но Docker при `context: ./docker` ищет `.dockerignore` **внутри** `./docker/`, а не в корне.

**Файлы:** Создать `docker/.dockerignore` или перепроверить, что текущий `.dockerignore` действительно применяется.

**Что сделать:** Создать файл `docker/.dockerignore` с содержимым:

```
# Секреты и конфиги, которые НЕ должны попасть в production-образ
../.env
../.env.*
../.git
../.idea
../.vscode
../docker-compose*.yml
../Makefile
../docs/
../*.md
../docker/
../tests/
../phpunit.xml
../.phpunit.result.cache
../node_modules/
```


**Альтернатива (рекомендуемая):** Перенести build context на корень проекта. В `docker-compose.yml` изменить:

```yaml
laravel-php-nginx-socket:
    build:
      context: .
      dockerfile: docker/php.Dockerfile
      target: php-base
```


И соответственно адаптировать пути `COPY` в `docker/php.Dockerfile`:
- `COPY ./php/www.conf` → `COPY ./docker/php/www.conf`
- `COPY ./php/php.ini` → `COPY ./docker/php/php.ini`
- `COPY ../ ./` → `COPY . ./`

Тогда корневой `.dockerignore` будет корректно работать.

**Критерий приёмки:** `docker build --target production -t test-img -f docker/php.Dockerfile . && docker run --rm test-img ls -la /var/www/laravel/.env` — файл отсутствует (exit code 2).

---

### ЗАДАЧА 9 — [MEDIUM] PostgreSQL backup-стратегия (документация + опциональный сервис)

**Проблема:** Нет никакой стратегии бэкапов для PostgreSQL. Для long-term production это критично.

**Файлы:** `docker-compose.prod.yml`, `docs/backup-strategy.md` (создать)

**Что сделать:**

1. Добавить опциональный сервис backup в `docker-compose.prod.yml`:

```yaml
# Опционально: ежедневный бэкап PostgreSQL
  # Включить через: docker compose --profile backup up -d
  laravel-backup-nginx-socket:
    image: postgres:18.2-alpine
    profiles:
      - backup
    restart: unless-stopped
    environment:
      PGHOST: laravel-postgres-nginx-socket
      PGUSER: ${DB_USERNAME}
      PGPASSWORD: ${DB_PASSWORD}
      PGDATABASE: ${DB_DATABASE}
    volumes:
      - ./backups:/backups
    networks:
      - laravel-nginx-socket-network
    command: >
      sh -c 'while true; do
        pg_dump -Fc > /backups/$$(date +%Y%m%d_%H%M%S).dump
        find /backups -name "*.dump" -mtime +7 -delete
        sleep 86400
      done'
    depends_on:
      laravel-postgres-nginx-socket:
        condition: service_healthy
```


2. Создать файл `docs/backup-strategy.md` с описанием:
    - Как включить автоматические бэкапы
    - Как восстановить из бэкапа (`pg_restore`)
    - Рекомендация по хранению (минимум 7 дней)
    - Рекомендация по выносу бэкапов на внешнее хранилище

**Критерий приёмки:** Документ создан. Сервис запускается через `--profile backup` и создаёт `.dump` файлы.

---

### ЗАДАЧА 10 — [LOW] Scheduler: заменить `sleep 60` на supercronic

**Проблема:** Текущая реализация scheduler (`while true; do php artisan schedule:run; sleep 60; done`) имеет небольшой drift по времени — каждый цикл смещается на время выполнения `schedule:run`. Для точного расписания (minute-level precision) это может приводить к пропуску тиков.

**Файлы:** `docker/php.Dockerfile`, `docker-compose.yml`

**Что сделать:**

1. В `docker/php.Dockerfile`, в stage `php-base`, после установки Composer, добавить установку supercronic:

```dockerfile
# 7) Supercronic — cron для контейнеров (точный тайминг, stdout/stderr логи)
ARG SUPERCRONIC_ARCH=linux-amd64
RUN set -eux; \
    SUPERCRONIC_URL="https://github.com/aptible/supercronic/releases/latest/download/supercronic-${SUPERCRONIC_ARCH}"; \
    curl -fsSL "${SUPERCRONIC_URL}" -o /usr/local/bin/supercronic; \
    chmod +x /usr/local/bin/supercronic
```


2. Создать файл `docker/php/scheduler-crontab`:

```
* * * * * php /var/www/laravel/artisan schedule:run --verbose --no-interaction
```


3. В `docker/php.Dockerfile`, скопировать crontab:

```dockerfile
COPY ./php/scheduler-crontab /etc/scheduler-crontab
```


4. В `docker-compose.yml`, изменить command scheduler:

```yaml
laravel-scheduler-nginx-socket:
    # ... existing code ...
    command: ["supercronic", "/etc/scheduler-crontab"]
    # ... existing code ...
```


**Критерий приёмки:** Scheduler запускает `schedule:run` ровно раз в минуту без drift. Логи видны через `docker logs`.

---

### ЗАДАЧА 11 — [LOW] Добавить Makefile-команду для валидации compose-конфигов

**Проблема:** Нет быстрого способа проверить, что все overlay compose-файлы корректно мержатся. Ошибки в YAML обнаруживаются только при `up`.

**Файл:** `Makefile`

**Что сделать:** Добавить команды:

```makefile
validate-compose: ## Проверить корректность всех compose-конфигураций
	@echo "$(YELLOW)Проверка dev compose...$(NC)"
	@$(COMPOSE_DEV) config --quiet && echo "$(GREEN)✓ Dev OK$(NC)" || echo "$(RED)✗ Dev FAILED$(NC)"
	@echo "$(YELLOW)Проверка prod compose...$(NC)"
	@$(COMPOSE_PROD) config --quiet && echo "$(GREEN)✓ Prod OK$(NC)" || echo "$(RED)✗ Prod FAILED$(NC)"
	@echo "$(YELLOW)Проверка test compose...$(NC)"
	@$(COMPOSE_TEST) config --quiet && echo "$(GREEN)✓ Test OK$(NC)" || echo "$(RED)✗ Test FAILED$(NC)"
```


**Критерий приёмки:** `make validate-compose` выводит статус для всех трёх конфигов.

---

### ЗАДАЧА 12 — [LOW] Мониторинг: рекомендации в документации

**Проблема:** Нет рекомендаций по мониторингу и алертингу. Проблемы в production обнаруживаются только после жалоб пользователей.

**Файл:** Создать `docs/monitoring.md`

**Что сделать:** Создать документ с рекомендациями:

- **Laravel Telescope** — для dev (отладка запросов, очередей, events)
- **Laravel Horizon** — для prod (мониторинг Redis-очередей, метрики)
- **FPM status page** — уже есть `ping.path = /ping`, добавить `pm.status_path = /fpm-status` в `www.conf` (доступ только из internal network)
- **Prometheus + Grafana** — как future step для серьёзного мониторинга
- **Nginx stub_status** — для мониторинга Nginx (active connections, requests/sec)

**Критерий приёмки:** Документ создан, содержит конкретные шаги установки для каждого инструмента.

---

## 3. Сводная таблица задач

| # | Приоритет | Задача | Файлы | Сложность |
|---|-----------|--------|-------|-----------|
| 1 | 🔴 HIGH | Gzip-компрессия в Nginx | `laravel.conf` | Низкая |
| 2 | 🔴 HIGH | Кеширование статики в Nginx | `laravel.conf` | Низкая |
| 3 | 🔴 HIGH | Rate-limiting в Nginx | `laravel.conf` | Средняя |
| 4 | 🔴 HIGH | Production FPM pool (`www.prod.conf`) | Новый файл + `php.Dockerfile` | Средняя |
| 5 | 🟡 MEDIUM | Nginx healthcheck (реальная проверка) | `docker-compose.yml` | Низкая |
| 6 | 🟡 MEDIUM | Консистентность networks в prod overlay | `docker-compose.prod.yml` | Низкая |
| 7 | 🟡 MEDIUM | Content-Security-Policy header | `laravel.conf` | Низкая |
| 8 | 🟡 MEDIUM | Защита build context (`.dockerignore`) | `.dockerignore` / Dockerfile / compose | Средняя |
| 9 | 🟡 MEDIUM | PostgreSQL backup-стратегия | `docker-compose.prod.yml` + docs | Средняя |
| 10 | 🟢 LOW | Scheduler: supercronic | `php.Dockerfile` + `docker-compose.yml` | Средняя |
| 11 | 🟢 LOW | Makefile: validate-compose | `Makefile` | Низкая |
| 12 | 🟢 LOW | Документация по мониторингу | Новый `docs/monitoring.md` | Низкая |

---

## 4. Рекомендуемый порядок выполнения

```
Задача 1 (gzip) → Задача 2 (cache headers) → Задача 3 (rate-limit)
    ↓
Задача 7 (CSP) — все 4 задачи в одном файле laravel.conf
    ↓
Задача 4 (www.prod.conf) — новый файл + правка Dockerfile
    ↓
Задача 8 (build context) — правка .dockerignore / compose / Dockerfile
    ↓
Задача 5 (nginx healthcheck) → Задача 6 (networks cleanup) — правки compose
    ↓
Задача 9 (backup) → Задача 10 (supercronic) → Задача 11 (validate) → Задача 12 (docs)
```


**Логика:** сначала все правки в одном файле (`laravel.conf`), затем Dockerfile/compose, затем документация.

---

## 5. Чего НЕ нужно менять

| Элемент | Причина |
|---------|---------|
| Postgres volume `/var/lib/postgresql` | Postgres 18+ требует этот путь |
| Redis без пароля | Внутренняя Docker-сеть, единственный потребитель, порты не публикуются в prod |
| Отсутствие `.env.example` | Появляется после установки Laravel (`composer create-project`) |
| Unix socket архитектура | Правильное решение, менять нельзя |
| Multi-stage Dockerfile | Корректная реализация |
| Overlay compose стратегия | Грамотное разделение |
| `php.prod.ini` / `php.ini` разделение | Уже реализовано корректно |

---

## 6. Ожидаемый результат после доработки

После выполнения всех 12 задач оценка проекта повышается с **7.5/10** до **9/10**:

| Критерий | Было | Станет |
|----------|------|--------|
| Безопасность | 6/10 | 8.5/10 |
| Производительность | 6.5/10 | 9/10 |
| Логирование и мониторинг | 6/10 | 7.5/10 |
| DevOps | 7/10 | 8.5/10 |