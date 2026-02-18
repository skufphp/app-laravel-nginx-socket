## План работ: адаптация **ansible-starter** → **ansible-laravel-internal** (Laravel + internal PostgreSQL + internal Redis + migrate job, всё через CI/CD)

Ниже — детальный, “проектный” план, который можно брать как чек‑лист и выполнять по шагам. Цель: получить репозиторий **ansible-laravel-internal**, который будет использоваться как CI/CD‑шаблон для Laravel‑проектов, где **PostgreSQL и Redis поднимаются в Docker Compose на сервере**, а миграции выполняются **one-off job’ом** после `up -d`.

---

## 0) Зафиксировать “контракт” деплоя (что именно будет делать шаблон)

### 0.1. Что шаблон деплоя делает на сервере
1) Подготавливает директорию деплоя (`DEPLOY_PATH`)
2) Кладёт туда нужные compose-файлы (base + prod overlay)
3) Создаёт **runtime env-файл для Laravel** (например `.env.prod`) из GitLab Variables
4) Делает `docker login` в GitLab Registry
5) Делает `docker compose pull`
6) Делает `docker compose up -d`
7) Делает `docker compose run --rm migrate` (Laravel migrations)
8) (опционально) делает `prune` образов
9) Делает `docker logout`

### 0.2. Что деплой НЕ делает
- НЕ хранит секреты в репозитории
- НЕ запускает `migrate:fresh` (прод не должен терять данные)
- НЕ публикует наружу 5432/6379 (если не нужно)

---

## 1) Создать новый репозиторий-шаблон: **ansible-laravel-internal**

### 1.1. Структура репо (рекомендую)
- `ansible/`
  - `inventories/production.ini.tpl`
  - `playbooks/deploy.yml`
  - `roles/`
    - `docker_compose_app/` (опционально, но лучше чем один большой плейбук)
      - `tasks/main.yml`
      - `templates/env.prod.j2`
- `gitlab/laravel-deploy.yml` (GitLab CI template)
- `README.md`, `WORKFLOW.md`

> Можно начать “без ролей” и оставить playbook, но как только добавятся staging/blue‑green/cron/queue — роли окупятся.

---

## 2) Привести CI template к реальности Laravel-стека (2 образа: php + nginx)

Сейчас starter-логика обычно заточена под **один Dockerfile → один образ**. Ваш Laravel boilerplate в prod использует **два образа**: `php` и `nginx`.

### 2.1. Решение: стандарт тегов и имён образов
Выберите конвенцию:
- `CI_REGISTRY_IMAGE/php:$IMAGE_TAG`
- `CI_REGISTRY_IMAGE/nginx:$IMAGE_TAG`

И “latest”:
- `CI_REGISTRY_IMAGE/php:latest`
- `CI_REGISTRY_IMAGE/nginx:latest`

### 2.2. Изменить stage build: собирать и пушить оба образа
В шаблоне CI (**ansible-laravel-internal**) нужно:
- build/push PHP image (target `production` вашего multi-stage)
- build/push Nginx image
- (опционально) кеширование buildkit

**Проверка результата:** после pipeline в Registry должны появляться **2 артефакта**.

---

## 3) Стандартизировать compose на сервере: base + prod overlay

### 3.1. Что держим на сервере
В `DEPLOY_PATH` должны оказаться:
- `docker-compose.yml` (base: php+nginx+postgres+redis+volumes+networks)
- `docker-compose.prod.yml` (overlay: `image:` для php/nginx + `migrate` job + прод-порты/лейблы)
- `.env.compose` (переменные для подстановки в compose, например `CI_REGISTRY_IMAGE`, `IMAGE_TAG`)
- `.env.prod` (runtime env для Laravel внутри контейнеров: `APP_KEY`, `DB_*`, `REDIS_*`, etc.)

> Важно разделять:
> - `.env.compose` — для подстановки `${...}` в compose
> - `.env.prod` — для Laravel runtime

### 3.2. Принцип подключения env в compose
В `docker-compose.prod.yml` (в ваших Laravel проектах) вы должны договориться, что:
- сервис `laravel-php...` и `migrate` читают `env_file: .env.prod`
- при необходимости Postgres/Redis тоже читают часть env (например пароли)

---

## 4) Адаптировать Ansible playbook: деплой “по-ларовски”

### 4.1. Передаваемые переменные в Ansible (источник: GitLab Variables)
Обязательные (примерный минимум):
- SSH/host:
  - `PROD_HOST`, `PROD_USER`, `PROD_SSH_PORT`, `DEPLOY_PATH`
- Registry:
  - `CI_REGISTRY`, `CI_REGISTRY_USER`, `CI_REGISTRY_PASSWORD`
  - `CI_REGISTRY_IMAGE`
  - `IMAGE_TAG` (обычно `CI_COMMIT_SHORT_SHA`)
- Laravel runtime:
  - `APP_KEY`, `APP_ENV`, `APP_DEBUG=false`, `APP_URL`
  - `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` (и любые нужные DB options)
  - `REDIS_PASSWORD` (если “приближённо к prod”)
  - (опционально) `CACHE_STORE`, `SESSION_DRIVER`, `QUEUE_CONNECTION`

> Значения секретов — только плейсхолдеры/Variables, ничего в git.

### 4.2. Изменения в `deploy.yml` (логика задач)
Порядок задач рекомендую такой:

1) **Ensure deploy directory exists**
2) **Upload docker-compose.yml** (base)  
3) **Upload docker-compose.prod.yml** (overlay)  
4) **Write `.env.compose`** (CI_REGISTRY_IMAGE, IMAGE_TAG и любые compose-подстановки)
5) **Write `.env.prod`** из шаблона Jinja2 (`env.prod.j2`)  
   - `mode: "0600"`
   - `no_log: true` (важно, чтобы секреты не утекали в вывод)
6) **Docker login** (`no_log: true`)
7) **Pull images**:  
   `docker compose --env-file .env.compose -f docker-compose.yml -f docker-compose.prod.yml pull`
8) **Up containers**:  
   `docker compose --env-file .env.compose -f docker-compose.yml -f docker-compose.prod.yml up -d`
9) **Run migrations one-off**:  
   `docker compose --env-file .env.compose -f docker-compose.yml -f docker-compose.prod.yml run --rm migrate`
10) **(Опционально) Prune images**
11) **Docker logout**

### 4.3. Важное: ожидание готовности Postgres перед миграциями
Есть два подхода:
- **depends_on + healthcheck** (в compose) — хорошо, но “condition: service_healthy” в prod на разных compose версиях/плагинах может вести себя по-разному.
- **ждать в `migrate` command** (ретраи) — самый переносимый вариант.

Для production‑надёжности я бы сделал **двойную страховку**:
- healthcheck у Postgres в compose
- + migrate job с retry (например 30–60 секунд попыток) перед `php artisan migrate --force`

---

## 5) Добавить шаблон `.env.prod` в ansible-laravel-internal

### 5.1. Что кладём в `templates/env.prod.j2`
Минимальный набор:

- Laravel:
  - `APP_NAME`, `APP_ENV`, `APP_DEBUG`, `APP_URL`, `APP_KEY`
  - `LOG_CHANNEL` (опционально)
- DB (internal):
  - `DB_CONNECTION=pgsql`
  - `DB_HOST=<service-name-postgres>` (имя сервиса из compose)
  - `DB_PORT=5432`
  - `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`
- Redis (internal):
  - `REDIS_HOST=<service-name-redis>`
  - `REDIS_PORT=6379`
  - `REDIS_PASSWORD` (если включили `requirepass`)
  - `CACHE_STORE=redis` и т.д. (если хотите дефолт)

### 5.2. Как избежать “мусора” в `.env.prod`
- Не тащить dev-переменные (xdebug/vite/порты)
- Не копировать весь `.env.example`, только нужное

---

## 6) Обновить inventory-часть (как минимум оставить как есть, но расширить)

### 6.1. `production.ini.tpl`
Оставить текущий подход через `envsubst`, но добавить опции:
- `ansible_become=true` (если надо)
- `ansible_python_interpreter=/usr/bin/python3` (если на сервере нестандартно)

---

## 7) Обновить verify/healthcheck в CI шаблоне

Для Laravel лучше, чем просто “главная страница”, иметь:
- `/health` или `/up` (если добавите маршрут)
- или `GET /` + проверка `200`

В шаблоне `ansible-laravel-internal` можно оставить URL как input (`app_url`), но в README прямо рекомендовать endpoint “без авторизации”.

---

## 8) Продумать “приближенно к prod” для Redis/Postgres (в internal модели)

Чтобы ваш internal‑boilerplate был действительно “как прод”:

### 8.1. Redis
- включить пароль (`requirepass`)
- healthcheck делать с `-a $REDIS_PASSWORD`
- не публиковать 6379 наружу в prod

### 8.2. Postgres
- не публиковать 5432 наружу в prod
- volume обязателен
- пароль обязателен
- бэкапы — отдельная задача (можно как future step: отдельный cron/job)

---

## 9) Документация репозитория **ansible-laravel-internal**

### 9.1. README должен отвечать на 5 вопросов
1) Как подключить include в `.gitlab-ci.yml`
2) Какие GitLab Variables обязательны (таблица)
3) Что будет создано на сервере (`DEPLOY_PATH`, какие файлы)
4) Как устроен порядок деплоя (pull → up → migrate → healthcheck)
5) Как откатиться (как минимум: задеплоить предыдущий `IMAGE_TAG`)

### 9.2. WORKFLOW
Опишите:
- MR pipeline (lint/build)
- main pipeline (build+push, deploy, verify)
- запрет параллельных деплоев в production (environment lock / manual)

---

## 10) План по этапам (как реально делать, чтобы не сломать)

### Этап A — “скелет”
1) Скопировать ansible-starter → новый repo ansible-laravel-internal
2) Переименовать CI template файл и README под Laravel
3) В Ansible playbook научиться копировать **оба compose файла** + писать `.env.compose`

**Готовность:** деплой поднимает nginx/php (без миграций пока).

### Этап B — “runtime env + миграции”
4) Добавить шаблон `.env.prod.j2` + генерацию `.env.prod` на сервере
5) Включить `env_file` в compose для php и migrate (на стороне Laravel‑проектов)
6) Добавить шаг `docker compose run --rm migrate`

**Готовность:** после деплоя база инициализируется миграциями.

### Этап C — “два образа”
7) Переделать CI build/push на **php и nginx** образы
8) Убедиться, что prod overlay тянет правильные имена images

**Готовность:** полноценный релизный пайплайн.

### Этап D — “prod-like hardening”
9) Redis с паролем + healthchecks
10) Права на `.env.prod` = `0600`, `no_log: true`
11) Откат по тегу, документация

---

## Что нужно от вас перед стартом нового чата (2 уточнения, чтобы план стал “исполняемым без догадок”)
1) Вы деплоите на **один сервер** (docker compose на VPS) или планируете несколько хостов?  
2) Хотите, чтобы deploy job был **manual** (кнопка) или **автоматически** на `main`?

В новом чате по **ansible-laravel-internal** мы начнём с “Этап A” и я буду вести вас по шагам, предлагая конкретные правки файлов (playbook, templates, gitlab template) и проверки после каждого шага.