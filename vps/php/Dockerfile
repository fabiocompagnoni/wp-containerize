ARG PHP_APACHE_IMAGE
FROM ${PHP_APACHE_IMAGE}

# Generic PHP site served by Apache with mod_php: PrestaShop and hand-written PHP sites.
# The code of the site is never in the image: it is mounted from sites/<site>/html, so the
# application updates itself (e.g. the PrestaShop Update Assistant) as on a classic hosting.
# Apache, not nginx: these applications ship .htaccess rules (and modules add new ones),
# read as they are with AllowOverride All.
# mariadb-client: dump import at the first start; curl: health check
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        mariadb-client curl \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libavif-dev \
        libzip-dev libicu-dev libxml2-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-avif; \
    docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli gd intl zip bcmath soap exif; \
    # OPcache is part of PHP itself from 8.5; older versions build it as an extension
    if ! php -m | grep -qx 'Zend OPcache'; then docker-php-ext-install opcache; fi; \
    rm -rf /var/lib/apt/lists/*; \
    # every extension PrestaShop and its dependencies require (composer.json/lock)
    for ext in bcmath ctype curl dom exif fileinfo filter gd iconv intl json libxml mbstring \
               mysqli openssl pcre PDO pdo_mysql SimpleXML soap sodium tokenizer xml \
               xmlreader xmlwriter zip zlib 'Zend OPcache'; do \
        php -m | grep -qix "$ext" || { echo "missing PHP extension: $ext" >&2; exit 1; }; \
    done; \
    a2enmod rewrite remoteip headers expires deflate access_compat; \
    a2dissite 000-default

COPY php/site.ini /usr/local/etc/php/conf.d/zz-site.ini
COPY apache/site.conf /etc/apache2/sites-available/site.conf
COPY apache/hardening.conf /etc/apache2/conf-available/zz-hardening.conf
COPY health/ /var/www/health/
COPY --chmod=0755 bin/ /usr/local/bin/
RUN set -eux; a2ensite site; a2enconf zz-hardening

# Apache prefork workers (one PHP request each): size them on the memory of the container
ENV APACHE_MAX_WORKERS=5

ENTRYPOINT ["php-bootstrap"]
CMD ["apache2-foreground"]
