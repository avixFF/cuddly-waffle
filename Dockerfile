ARG PHP_VERSION=7.2

#
# Base stage is used for both development and production.
# It is used to install application code and its dependencies.
#

FROM php:${PHP_VERSION}-fpm AS base

# Use docker-php-extension-installer
# Source: https://github.com/mlocati/docker-php-extension-installer#downloading-the-script-on-the-fly
ADD --chown=www-data:www-data https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && sync

# Download the package lists from the repositories
RUN apt-get update

# Install APT packages required for the modules
RUN apt-get install -y nginx expect libzstd-dev git libzip-dev unzip cron gettext-base moreutils

# Configure packages before installing them
RUN docker-php-ext-configure zip
RUN pecl install igbinary && docker-php-ext-enable igbinary

# Install PHP packages required for the modules
RUN docker-php-ext-install pdo_mysql zip pcntl

# Set up nginx to serve PHP-FPM application
COPY .docker-blueprint/blueprints/_/php/modules/nginx/default.conf.tmpl /etc/nginx/sites-available/default
RUN mkdir -p /var/www/.composer /.composer
RUN chown -R www-data: /var/www/.composer /.composer
RUN chmod -R 777 /var/www/.composer /.composer

ARG COMPOSER_VERSION

RUN install-php-extensions @composer-${COMPOSER_VERSION}
RUN expect -c'send y\n; send y\n; send y\n' | pecl install redis && docker-php-ext-enable redis
RUN mkdir -p /var/www/.npm /.npm /.config
RUN chown -R www-data: /var/www/.npm /.npm /.config
RUN chmod -R 775 /var/www/.npm /.npm /.config

RUN curl -sL https://deb.nodesource.com/setup_14.x | bash -
RUN apt-get install -y nodejs
RUN npm set progress=false
RUN touch /var/log/cron.log
RUN mkdir -p /etc/cron.d/

COPY .docker-blueprint/blueprints/_/php/env/laravel/modules/cron/table /etc/cron.d/table

# Give execution rights on the cron jobs
RUN chmod -R 0644 /etc/cron.d
# Apply all available cron jobs (https://unix.stackexchange.com/a/360947)
RUN cat /etc/cron.d/* | crontab -

# Laravel-specific dockerfile commands here

RUN apt-get clean

# Install s6 supervisor
# Reference: https://github.com/just-containers/s6-overlay#the-docker-way

ADD "https://github.com/just-containers/s6-overlay/releases/download/v2.2.0.3/s6-overlay-amd64.tar.gz" /tmp/
RUN gunzip -c /tmp/s6-overlay-amd64.tar.gz | tar -xf - -C /

COPY .docker-blueprint/blueprints/_/php/supervisor /etc
COPY .docker-blueprint/blueprints/_/php/modules/cron/supervisor/ /etc/
COPY .docker-blueprint/blueprints/_/php/modules/nginx/supervisor/ /etc/

COPY .docker-blueprint/blueprints/_/php/env/laravel/modules/horizon/supervisor/ /etc/

ENTRYPOINT ["/init"]

RUN mkdir /.docker-blueprint
RUN echo 'laravel' >/.docker-blueprint/env

#
# After the base stage has been built, it can
# be launched for development.
#

FROM base AS development

# clear_env must equal to 'no' as per https://stackoverflow.com/a/37062629/2467106
RUN ln -s /usr/local/etc/php/php.ini-development /usr/local/etc/php/php.ini

RUN groupadd -g 1000 local-workspace
RUN usermod -a -G local-workspace www-data

#
# In order to prepare the container for production,
# we need to copy project files, remove development
# packages # and compile assets.
#

FROM base AS production

WORKDIR /var/www/html

# Clear working directory
RUN rm -rf ./*

COPY --chown=www-data:www-data ["package.json", "package-lock.json", "/var/www/html/"]
RUN su www-data -s /bin/bash -c 'npm install --production'

COPY --chown=www-data:www-data ["composer.json", "composer.lock", "/var/www/html/"]

# Update ownership of `vendor` directory
RUN mkdir vendor
RUN chown -R www-data: vendor
RUN chmod -R 775 vendor

RUN [ "${COMPOSER_VERSION}" = "1" ] && \
su www-data -s /bin/bash -c 'composer global require hirak/prestissimo --no-scripts'; exit 0

RUN su www-data -s /bin/bash -c 'composer install --no-dev --no-suggest --no-scripts --no-autoloader'

RUN [ "${COMPOSER_VERSION}" = "1" ] && \
su www-data -s /bin/bash -c 'composer global remove hirak/prestissimo --no-scripts'; exit 0

RUN mkdir -p storage

WORKDIR storage
RUN mkdir -p logs && \
mkdir -p framework && \
mkdir -p framework/cache && \
mkdir -p framework/cache/data && \
mkdir -p framework/sessions && \
mkdir -p framework/testing && \
mkdir -p framework/views
# RUN touch logs/laravel.log
WORKDIR ..

# Update ownership of `storage` directory
RUN chown -R www-data: storage
RUN chmod -R 775 storage

# # Copy project files
COPY --chown=www-data:www-data . /var/www/html

RUN npm run production

RUN composer dumpautoload --no-scripts

# Create dummy database to be able to call artisan commands
ENV DB_CONNECTION=sqlite
ENV DB_DATABASE=mock.sqlite
RUN touch $DB_DATABASE
# Clear config so it could be read from the environment variables later
RUN php artisan config:clear
RUN php artisan package:discover
RUN php artisan optimize
# Remove dummy database
RUN rm $DB_DATABASE

RUN ln -s /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

