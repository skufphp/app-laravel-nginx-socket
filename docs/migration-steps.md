## План работ (безопасно, шаг за шагом)

### Шаг 1. “Запекаем” конфиги в образы (чтобы prod не зависел от volumes)
Сейчас `php.ini`, `www.conf` и `nginx.conf` примонтированы. Это удобно в dev, но для prod/CI плохо: образ не self-contained.

Делаем:
- `docker/php.Dockerfile`: копируем `php.ini` внутрь (и сразу готовим multi-stage).
- `docker/nginx.Dockerfile`: копируем `laravel.conf` внутрь образа как `default.conf`.

Проверка: `docker compose up -d --build` (пока без разделения compose) — сайт должен работать как раньше.

---

### Шаг 2. Делаем `docker/php.Dockerfile` multi-stage (targets)
Цель:
- `php-base` — рантайм PHP (без Node) + расширения + composer + конфиги
- `frontend-build` — сборка `public/build`
- `production` — финальный PHP-образ + копия `public/build`

В dev мы будем собирать `php-base`, а HMR будет жить в отдельном `node` сервисе.

---

### Шаг 3. Режем compose на base + dev overlay
- `docker-compose.yml` становится **общим**: только “скелет” (php + nginx, сеть, unix-socket volume). Без портов и без bind-mount кода.
- `docker-compose.dev.yml` добавляет:
    - порты (nginx наружу, vite 5173)
    - bind-mount проекта `.:/var/www/laravel`
    - node-сервис (npm ci + npm run dev)
    - postgres + pgadmin (dev-only)

Проверка:
- `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build`
- открой сайт, проверь HMR (из браузера должен быть доступен `http://localhost:5173`).

---

### Шаг 4. Prod compose как CI/CD overlay
- `docker-compose.prod.yml` **не билдит**, а только указывает `image: ${CI_REGISTRY_IMAGE}/...:${IMAGE_TAG}`
- никаких bind-mount кода
- минимальные ports (обычно только nginx)

Проверка:
- `docker compose -f docker-compose.yml -f docker-compose.prod.yml config` (проверить итоговую склейку)
- (локально можно протестировать, подставив временные `image`)

---

## Правки файлов (конкретика)

### 1) Nginx Dockerfile: запечь конфиг внутрь образа
```dockerfile
# ==============================================================================
# Dockerfile для Nginx
# Базовый образ: Nginx на Alpine Linux (минималистичный и производительный)
# ==============================================================================
FROM nginx:alpine

# Добавляем пользователя nginx в группу www-data
# Это необходимо для того, чтобы Nginx мог читать/писать в UNIX-сокет,
# владельцем которого является пользователь www-data (из PHP-FPM)
RUN addgroup nginx www-data

# Рабочая директория (соответствует PHP-контейнеру)
WORKDIR /var/www/laravel

# ... existing code ...

# Вшиваем конфиг виртуального хоста в образ (prod-friendly).
# В dev при желании можно будет переопределить volume-ом.
COPY ./nginx/conf.d/laravel.conf /etc/nginx/conf.d/default.conf
```


---

### 2) PHP Dockerfile: превращаем в multi-stage и убираем Node из рантайма
```dockerfile
# ==============================================================================
# Multi-stage PHP-FPM Image (Unix Socket) — PHP 8.5 Alpine (Laravel)
# ==============================================================================
FROM node:20-alpine AS frontend-build
WORKDIR /app

# Ставим зависимости фронта отдельно для лучшего кеширования
COPY ../package*.json ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Копируем проект и собираем ассеты
COPY ../ ./
RUN npm run build


# ==============================================================================
# PHP base runtime (no node) — used for dev target and as base for production
# ==============================================================================
FROM php:8.5-fpm-alpine AS php-base

# 1) Runtime deps + Build deps (build deps удалим после сборки)
RUN set -eux; \
    apk add --no-cache \
      curl git zip unzip fcgi \
      icu-libs libzip libpng libjpeg-turbo freetype postgresql-libs libxml2 oniguruma \
    && apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS linux-headers \
      icu-dev libzip-dev libpng-dev libjpeg-turbo-dev freetype-dev \
      postgresql-dev libxml2-dev oniguruma-dev

# 2) PHP extensions
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      pdo \
      pdo_pgsql \
      pgsql \
      mbstring \
      xml \
      gd \
      bcmath \
      zip \
      intl

# 3) PIE (PHP Installer for Extensions) + Xdebug (dev only)
COPY --from=ghcr.io/php/pie:bin /pie /usr/bin/pie

ARG INSTALL_XDEBUG=false
RUN set -eux; \
    if [ "${INSTALL_XDEBUG}" = "true" ]; then \
      pie install xdebug/xdebug; \
      docker-php-ext-enable xdebug; \
    fi

# 4) Cleanup
RUN set -eux; \
    apk del .build-deps; \
    rm -rf /tmp/pear ~/.pearrc /var/cache/apk/*

# 5) PHP-FPM config (unix socket) + php.ini
RUN rm -f \
      /usr/local/etc/php-fpm.d/www.conf.default \
      /usr/local/etc/php-fpm.d/zz-docker.conf

COPY ./php/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY ./php/php.ini /usr/local/etc/php/conf.d/local.ini

RUN mkdir -p /var/run/php && chown -R www-data:www-data /var/run/php

# 6) Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/laravel
RUN chown -R www-data:www-data /var/www/laravel

CMD ["php-fpm", "-F"]


# ==============================================================================
# Production target: code + built assets baked in (immutable)
# ==============================================================================
FROM php-base AS production
WORKDIR /var/www/laravel

COPY ../ ./
COPY --from=frontend-build /app/public/build /var/www/laravel/public/build
```


> Важно: тут используется `COPY ../...` потому что build context у тебя сейчас `./docker`. В следующем шаге (compose) мы это учтём и будем собирать PHP из `./docker`, как и раньше.

---

### 3) Base compose: только общий скелет (без портов, без bind mounts, без dev-сервисов)
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

volumes:
  unix-socket:

networks:
  laravel-php-nginx-socket-network:
    driver: bridge
```


---

### 4) Dev overlay compose: порты, bind mounts, node(HMR), postgres, pgadmin
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
      - node

  node:
    image: node:20-alpine
    container_name: laravel-node-hmr
    working_dir: /var/www/laravel
    volumes:
      - .:/var/www/laravel
      - node_modules:/var/www/laravel/node_modules
    command: sh -lc "npm ci && npm run dev -- --host 0.0.0.0 --port 5173"
    ports:
      - "5173:5173"
    networks:
      - laravel-php-nginx-socket-network

  laravel-postgres-nginx-socket:
    image: postgres:17-alpine
    container_name: laravel-postgres-nginx-socket
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_DATABASE}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    ports:
      - "${DB_FORWARD_PORT}:5432"
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
  postgres-data:
```


---

### 5) Prod overlay compose: только образы из registry (CI/CD), без build и без bind mounts
```yaml
services:
  laravel-php-nginx-socket:
    image: "${CI_REGISTRY_IMAGE}/php:${IMAGE_TAG}"
    restart: unless-stopped
    build: null

  laravel-nginx-socket:
    image: "${CI_REGISTRY_IMAGE}/nginx:${IMAGE_TAG}"
    restart: unless-stopped
    build: null
    ports:
      - "8000:80"
```


> Здесь предполагается, что CI будет публиковать **два образа**: `php` (target `production`) и `nginx`. Если хочешь один образ — это отдельная архитектура (не ваш текущий socket-стек).

---

## Как запускать теперь

### Dev (с HMR)
```shell script
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```


### Prod (на сервере/в деплое)
```shell script
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

---
