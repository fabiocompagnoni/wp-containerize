ARG WORDPRESS_IMAGE
FROM ${WORDPRESS_IMAGE}

ARG WP_CLI_VERSION
ARG WP_CLI_SHA512
ARG REDIS_CACHE_VERSION
ARG NGINX_HELPER_VERSION

# mariadb-client: wp-cli db import/export; coreutils/tar: GNU tools used by the scripts;
# fcgi: health checks and smoke tests against PHP-FPM; msmtp: email through the SMTP of the site (sendmail_path); phpredis: object cache
RUN set -eux; \
    apk add --no-cache mariadb-client coreutils tar fcgi msmtp; \
    apk add --no-cache --virtual .build-deps $PHPIZE_DEPS; \
    pecl install redis; \
    docker-php-ext-enable redis; \
    apk del --no-network .build-deps; \
    rm -rf /tmp/pear

# wp-cli, verified against the published SHA-512
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
    echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c -; \
    chmod 0755 /usr/local/bin/wp

# Plugins copied into the site at first start (no Internet needed): Redis Object Cache
# (object cache) and Nginx Helper (deletes cached pages when they change, see wp-page-cache)
RUN set -eux; \
    mkdir -p /usr/src/wp-extras/plugins; \
    for plugin in "redis-cache.${REDIS_CACHE_VERSION}" "nginx-helper.${NGINX_HELPER_VERSION}"; do \
        curl -fsSL -o /tmp/plugin.zip "https://downloads.wordpress.org/plugin/${plugin}.zip"; \
        php -r '$z = new ZipArchive(); $z->open("/tmp/plugin.zip") === true || exit(1); $z->extractTo("/usr/src/wp-extras/plugins") || exit(1);'; \
        rm -f /tmp/plugin.zip; \
    done

COPY php/production.ini /usr/local/etc/php/conf.d/zz-production.ini
COPY php/fpm-pool.conf /usr/local/etc/php-fpm.d/zz-pool.conf
COPY --chmod=0755 bin/ /usr/local/bin/

ENTRYPOINT ["wp-bootstrap"]
CMD ["php-fpm"]
