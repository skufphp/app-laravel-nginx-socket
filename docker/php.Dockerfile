# ==============================================================================
# Многоэтапный образ PHP-FPM (Unix Socket) — PHP 8.5 Alpine (Laravel)
# ==============================================================================
# Назначение:
# - Сборка фронтенда (Node.js)
# - Базовая среда PHP (FPM)
# - Поддержка Xdebug для разработки
# - Оптимизированный Production образ
#
# Context: корень проекта (.)
# Stages:
#   frontend-build — сборка фронтенд-ассетов
#   php-base       — общая база: PHP, ext, composer (без php.ini, USER, CMD)
#   development    — dev-среда: php.ini, USER, CMD
#   production     — prod-образ: php.prod.ini, код, vendor, USER, CMD
# ==============================================================================

FROM node:24-alpine AS frontend-build
WORKDIR /app

# Ставим зависимости фронта отдельно для лучшего кеширования
COPY package*.json ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Копируем проект и собираем ассеты
COPY . ./
RUN npm run build


# ==============================================================================
# Базовая среда PHP (без node) — только общая база для всех окружений
# ==============================================================================
FROM php:8.5-fpm-alpine AS php-base

# PIE (PHP Installer for Extensions)
COPY --from=ghcr.io/php/pie:bin /pie /usr/bin/pie

# Зависимости времени выполнения (Runtime) + Зависимости для сборки (build dependencies) (удалим после компиляции)
RUN set -eux; \
    apk add --no-cache \
      curl git zip unzip fcgi \
      icu-libs libzip libpng libjpeg-turbo freetype postgresql-libs libxml2 oniguruma \
    && apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS linux-headers \
      icu-dev libzip-dev libpng-dev libjpeg-turbo-dev freetype-dev \
      postgresql-dev libxml2-dev oniguruma-dev

# PHP расширения + phpredis
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      pdo_pgsql \
      pgsql \
      gd \
      bcmath \
      zip \
      intl \
      sockets \
      pcntl; \
    pie install phpredis/phpredis

# Очистка временных файлов
RUN set -eux; \
    apk del .build-deps; \
    rm -rf /tmp/pear ~/.pearrc /var/cache/apk/*

# Установка Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Конфигурация PHP-FPM (unix socket) + php.ini
RUN rm -f \
      /usr/local/etc/php-fpm.d/www.conf.default \
      /usr/local/etc/php-fpm.d/zz-docker.conf \
      /usr/local/etc/php-fpm.d/www.conf

# Копируем конфигурацию PHP-FPM для Unix Socket
COPY docker/php/www.conf /usr/local/etc/php-fpm.d/www.conf

# Создаём директорию для Unix Socket и устанавливаем права
RUN mkdir -p /var/run/php && chown -R www-data:www-data /var/run/php

WORKDIR /var/www/laravel

# Создаём пользователя www-data (если не существует) и назначаем права
RUN addgroup -g 82 -S www-data 2>/dev/null || true; \
    adduser -u 82 -D -S -G www-data www-data 2>/dev/null || true; \
    chown -R www-data:www-data /var/www/laravel

# Graceful shutdown — PHP-FPM корректно завершает обработку запросов
STOPSIGNAL SIGQUIT

# ==============================================================================
# Development образ: dev php.ini, монтируется volume с кодом хоста
# ==============================================================================
FROM php-base AS development

# Xdebug (только для разработки)
ARG INSTALL_XDEBUG=false
RUN set -eux; \
    if [ "${INSTALL_XDEBUG}" = "true" ]; then \
      apk add --no-cache --virtual .xdebug-build-deps \
        $PHPIZE_DEPS \
        linux-headers; \
      pie install xdebug/xdebug; \
      docker-php-ext-enable xdebug; \
      apk del .xdebug-build-deps; \
    fi

# Конфигурация php.ini для разработки
COPY docker/php/php.ini /usr/local/etc/php/conf.d/local.ini

USER www-data

CMD ["php-fpm", "-F"]

# ==============================================================================
# Production образ: код + собранные ассеты (идеально для деплоя)
# ==============================================================================
FROM php-base AS production

# Переключаемся на root для установки зависимостей
USER root

WORKDIR /var/www/laravel

# Production php.ini (заменяет dev-конфиг)
COPY docker/php/php.prod.ini /usr/local/etc/php/conf.d/local.ini

# Копируем composer-файлы отдельно для кеширования слоя vendor
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader --no-interaction --no-scripts --no-progress

# Копируем код приложения
COPY . ./

# Удаляем public/hot, чтобы отключить Vite dev-server режим в production
RUN rm -f public/hot

# Копируем собранные фронтенд-ассеты
COPY --from=frontend-build /app/public/build /var/www/laravel/public/build

# Удаляем dev-кеши, скопированные с хоста
# Перегенерируем autoload и запускаем package:discover один раз
RUN rm -rf bootstrap/cache/*.php \
    && rm -rf storage/framework/cache/data/* \
    && mkdir -p \
      bootstrap/cache \
      storage/logs \
      storage/framework/cache/data \
      storage/framework/sessions \
      storage/framework/views \
    && composer dump-autoload --optimize --no-dev --classmap-authoritative --no-scripts \
    && php artisan package:discover --ansi

# Назначаем права и переключаемся на www-data
RUN chown -R www-data:www-data /var/www/laravel \
    && chmod -R ug+rwX storage bootstrap/cache
USER www-data

CMD ["php-fpm", "-F"]