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

# Очистка стандартных конфигураций PHP-FPM
# Мы заменяем их своими для настройки работы через UNIX-сокет
RUN rm -f \
        /usr/local/etc/php-fpm.d/www.conf.default \
        /usr/local/etc/php-fpm.d/zz-docker.conf

# Копирование кастомной конфигурации пула PHP-FPM
COPY ./php/www.conf /usr/local/etc/php-fpm.d/www.conf

# Гарантируем существование директории под Unix-сокеты
RUN mkdir -p /var/run/php && chown -R www-data:www-data /var/run/php

# Установка Composer (менеджер зависимостей PHP)
# Копируем бинарный файл из официального Docker-образа Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Устанавливаем рабочую директорию и гарантируем правильные права
WORKDIR /var/www/laravel

# Установка прав доступа (PHP-FPM в Alpine по умолчанию работает от www-data)
RUN chown -R www-data:www-data /var/www/laravel

# Запуск PHP-FPM в фоновом режиме (флаг -F заставляет его работать на переднем плане для Docker)
CMD ["php-fpm", "-F"]
