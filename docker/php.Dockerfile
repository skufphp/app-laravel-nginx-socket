# ==============================================================================
# PHP-FPM Custom Image (Unix Socket) — PHP 8.5 Alpine (Laravel)
# ==============================================================================
FROM php:8.5-fpm-alpine

# 1) Runtime deps + Build deps (build deps удалим после сборки)
RUN set -eux; \
    apk add --no-cache \
      curl git zip unzip fcgi \
      icu-libs libzip libpng libjpeg-turbo freetype postgresql-libs libxml2 oniguruma \
    && apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS linux-headers \
      icu-dev libzip-dev libpng-dev libjpeg-turbo-dev freetype-dev \
      postgresql-dev libxml2-dev oniguruma-dev

# 2) Node.js и NPM
# Устанавливаем их отдельным слоем. Это удобно, если тебе вдруг понадобится
# изменить версию ноды, не пересобирая расширения PHP.
RUN apk add --no-cache nodejs npm


# 3) PHP extensions
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

# 4) PIE (PHP Installer for Extensions) + Xdebug (dev only)
COPY --from=ghcr.io/php/pie:bin /pie /usr/bin/pie

ARG INSTALL_XDEBUG=false
RUN set -eux; \
    if [ "${INSTALL_XDEBUG}" = "true" ]; then \
      pie install xdebug/xdebug; \
      docker-php-ext-enable xdebug; \
    fi

# 5) Cleanup
RUN set -eux; \
    apk del .build-deps; \
    rm -rf /tmp/pear ~/.pearrc /var/cache/apk/*

# 6) PHP-FPM config (unix socket)
RUN rm -f \
      /usr/local/etc/php-fpm.d/www.conf.default \
      /usr/local/etc/php-fpm.d/zz-docker.conf

COPY ./php/www.conf /usr/local/etc/php-fpm.d/www.conf

RUN mkdir -p /var/run/php && chown -R www-data:www-data /var/run/php

# 7) Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/laravel
RUN chown -R www-data:www-data /var/www/laravel

CMD ["php-fpm", "-F"]
