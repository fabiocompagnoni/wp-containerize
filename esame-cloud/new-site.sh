#!/usr/bin/env bash
# Creates the directory of a new site instance:
#   sites/<name>/.env       settings (from .env.example)
#   sites/<name>/secrets/   generated passwords, TLS certificate in test mode
#   sites/<name>/html/      WordPress files (filled at the first start)
#   sites/<name>/import/    optional: files/wp-content/ and db.sql[.gz] of a site to migrate
#
# Usage: ./new-site.sh <name> <domain> [--test] [--port <https port>]
#   --test  self-signed certificate and no Cloudflare checks (local VM)
set -Eeuo pipefail

cd "$(dirname "$0")"

usage() { echo "usage: $0 <name> <domain> [--test] [--port <https port>]" >&2; exit 2; }
die()   { echo "error: $*" >&2; exit 1; }

[ $# -ge 2 ] || usage
name=$1 domain=$2; shift 2
mode=cloudflare port=443
while [ $# -gt 0 ]; do
    case "$1" in
        --test) mode=test ;;
        --port) [ $# -ge 2 ] || usage; port=$2; shift ;;
        *) usage ;;
    esac
    shift
done

[[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "name: lowercase letters, digits and '-' (max 31)"
[[ $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "invalid domain: $domain"
[[ $port =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || die "invalid port: $port"
command -v openssl >/dev/null || die "openssl is required"

site_dir="sites/$name"
[ ! -e "$site_dir" ] || die "$site_dir already exists"

umask 077
mkdir -p "$site_dir/html" "$site_dir/import/files" "$site_dir/secrets"
chmod 755 "$site_dir" "$site_dir/html" "$site_dir/import" "$site_dir/import/files"
chmod 700 "$site_dir/secrets"

# --- settings ---------------------------------------------------------------
site_url=""
if [ "$port" != 443 ]; then site_url="https://$domain:$port"; fi
sed -e "s|^SITE_NAME=.*|SITE_NAME=$name|" \
    -e "s|^SITE_DOMAIN=.*|SITE_DOMAIN=$domain|" \
    -e "s|^HTTPS_PORT=.*|HTTPS_PORT=$port|" \
    -e "s|^SITE_URL=.*|SITE_URL=$site_url|" \
    -e "s|^ORIGIN_MODE=.*|ORIGIN_MODE=$mode|" \
    -e "s|^WP_ADMIN_USER=.*|WP_ADMIN_USER=$name-admin|" \
    -e "s|^WP_ADMIN_EMAIL=.*|WP_ADMIN_EMAIL=admin@$domain|" \
    .env.example > "$site_dir/.env"
chmod 600 "$site_dir/.env"

# --- secrets (0644: read by the container users, the 0700 directory protects them)
secret() { printf '%s' "$2" > "$site_dir/secrets/$1"; chmod 644 "$site_dir/secrets/$1"; }
random_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

secret db_password "$(random_password)"
secret db_root_password "$(random_password)"
secret redis_password "$(random_password)"
secret wp_admin_password "$(random_password)"
secret wordfence_api_key ""
secret update_webhook_url ""

if [ "$mode" = test ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:$domain,DNS:www.$domain" \
        -keyout "$site_dir/secrets/origin_key.pem" -out "$site_dir/secrets/origin_cert.pem" 2>/dev/null
    # not used in test mode, but the compose file expects the file
    cp "$site_dir/secrets/origin_cert.pem" "$site_dir/secrets/origin_pull_ca.pem"
    chmod 644 "$site_dir"/secrets/*.pem
fi

cat <<EOF
Site "$name" created in $site_dir ($mode mode, HTTPS port $port).

Still to do:
EOF
if [ "$mode" = cloudflare ]; then
    cat <<EOF
  - Cloudflare files in $site_dir/secrets/ (mode 0644):
      origin_cert.pem, origin_key.pem   Origin CA certificate and key for $domain
      origin_pull_ca.pem                Authenticated Origin Pulls CA
EOF
fi
cat <<EOF
  - Wordfence API key in $site_dir/secrets/wordfence_api_key (updater)
  - to migrate a site: wp-content in $site_dir/import/files/wp-content,
    dump in $site_dir/import/db.sql (or db.sql.gz), DB_TABLE_PREFIX in .env

Start:  docker compose --env-file $site_dir/.env up -d --build
Admin:  user $name-admin, password in $site_dir/secrets/wp_admin_password
EOF
