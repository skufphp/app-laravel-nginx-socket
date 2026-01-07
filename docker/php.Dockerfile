# ==============================================================================
# PHP-FPM Custom Image (Unix Socket)
# ==============================================================================
FROM php:8.4-fpm-alpine

# 1. Системные зависимости
# Мы объединяем установку инструментов сборки ($PHPIZE_DEPS) и библиотек,
# которые нужны для работы PHP-расширений.
RUN apk add --no-cache \
    curl \
    $PHPIZE_DEPS \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libxml2-dev \
    zip \
    unzip \
    git \
    oniguruma-dev \
    libzip-dev \
    linux-headers \
    fcgi \
    postgresql-dev \
    icu-dev

# 2. Node.js и NPM
# Устанавливаем их отдельным слоем. Это удобно, если тебе вдруг понадобится
# изменить версию ноды, не пересобирая расширения PHP.
RUN apk add --no-cache nodejs npm

# 3. Компиляция PHP расширений и очистка
# Здесь мы устанавливаем Xdebug через PECL и встроенные расширения Laravel.
# В конце удаляем инструменты сборки ($PHPIZE_DEPS), чтобы образ весил меньше.
RUN pecl channel-update pecl.php.net \
    && pecl install xdebug \
    && docker-php-ext-enable xdebug \
    && docker-php-ext-install \
        pdo \
        pdo_pgsql \
        pgsql \
        mbstring \
        xml \
        gd \
        bcmath \
        zip \
        intl \
        opcache \
    && apk del $PHPIZE_DEPS

# Удаляем стандартные примеры конфигураций
RUN rm -f /usr/local/etc/php-fpm.d/zz-docker.conf

# Гарантируем существование директории под Unix-сокеты
RUN mkdir -p /var/run/php && chown -R www-data:www-data /var/run/php

# Устанавливаем Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Устанавливаем рабочую директорию и гарантируем правильные права
WORKDIR /var/www/laravel
RUN chown -R www-data:www-data /var/www/laravel

CMD ["php-fpm", "-F"]
