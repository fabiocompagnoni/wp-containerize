ARG VTIGER_PHP_IMAGE
FROM ${VTIGER_PHP_IMAGE}

# PHP extensions required by vtiger: mysqli, gd, imap (mail converter, mail manager),
# zip, intl, soap, bcmath, opcache. Debian base: the bundled imap extension needs the
# c-client library. The PHP version comes from VTIGER_PHP_IMAGE in build.env.
# mariadb-client: dump import at the first start; libfcgi-bin: health check (cgi-fcgi)
RUN set -eux; \
    # Debian 11 (base of the PHP 7.4 images) is end of life: its packages, security
    # updates included, are only on archive.debian.org
    . /etc/os-release; \
    if [ "$VERSION_CODENAME" = bullseye ]; then \
        printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list; \
        rm -f /etc/apt/sources.list.d/*; \
        echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        mariadb-client libfcgi-bin \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
        libzip-dev libicu-dev libxml2-dev libc-client-dev libkrb5-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure imap --with-kerberos --with-imap-ssl; \
    docker-php-ext-install -j"$(nproc)" mysqli gd zip intl soap bcmath imap opcache; \
    rm -rf /var/lib/apt/lists/*

COPY php/vtiger.ini /usr/local/etc/php/conf.d/zz-vtiger.ini
COPY php/fpm-pool.conf /usr/local/etc/php-fpm.d/zz-pool.conf
COPY --chmod=0755 bin/ /usr/local/bin/

ENTRYPOINT ["vtiger-bootstrap"]
CMD ["php-fpm"]
