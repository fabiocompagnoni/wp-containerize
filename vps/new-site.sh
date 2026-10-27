#!/usr/bin/env bash
# Creates the directory of a new site instance:
#   sites/<name>/.env       settings (from site.env.example)
#   sites/<name>/secrets/   generated passwords, TLS certificate in test mode
#   sites/<name>/html/      WordPress files (filled at the first start)
#   sites/<name>/import/    optional: files/wp-content/ and db.sql[.gz] of a site to migrate
#
# Usage: ./new-site.sh <name> <domain> [--test]
#   --test  self-signed certificate and no Cloudflare checks (local VM)
set -Eeuo pipefail

cd "$(dirname "$0")"
. ./lib.sh

usage() { echo "usage: $0 <name> <domain> [--test]" >&2; exit 2; }

[ $# -ge 2 ] || usage
name=$1 domain=$2; shift 2
mode=cloudflare
while [ $# -gt 0 ]; do
    case "$1" in
        --test) mode=test ;;
        *) usage ;;
    esac
    shift
done

valid_site_name "$name" || die "name: lowercase letters, digits and '-' (max 31), not 'edge'"
[[ $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "invalid domain: $domain"
command -v openssl >/dev/null || die "openssl is required"

site_dir="sites/$name"
[ ! -e "$site_dir" ] || die "$site_dir already exists"

umask 077
mkdir -p "$site_dir/html" "$site_dir/import/files" "$site_dir/secrets"
chmod 755 "$site_dir" "$site_dir/html" "$site_dir/import" "$site_dir/import/files"
chmod 700 "$site_dir/secrets"

# --- settings ---------------------------------------------------------------
site_net=$(free_site_net)
sed -e "s|^SITE_NAME=.*|SITE_NAME=$name|" \
    -e "s|^SITE_DOMAIN=.*|SITE_DOMAIN=$domain|" \
    -e "s|^SITE_NET=.*|SITE_NET=$site_net|" \
    -e "s|^ORIGIN_MODE=.*|ORIGIN_MODE=$mode|" \
    -e "s|^WP_ADMIN_USER=.*|WP_ADMIN_USER=$name-admin|" \
    -e "s|^WP_ADMIN_EMAIL=.*|WP_ADMIN_EMAIL=admin@$domain|" \
    site.env.example > "$site_dir/.env"
chmod 600 "$site_dir/.env"

# --- secrets (0644: read by the container users and the edge, the 0700 directory protects them)
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
    chmod 644 "$site_dir"/secrets/*.pem
fi

cat <<EOF
Site "$name" created in $site_dir ($mode mode, networks $(site_net_prefix "$name").0/24).

Still to do:
EOF
if [ "$mode" = cloudflare ]; then
    cat <<EOF
  - Cloudflare files in $site_dir/secrets/ (mode 0644):
      origin_cert.pem, origin_key.pem   Origin CA certificate and key for $domain
EOF
fi
cat <<EOF
  - Wordfence API key in $site_dir/secrets/wordfence_api_key (updater)
  - to migrate an existing site use migrate-site.sh instead

Start:  ./site.sh $name up -d --wait && ./edge.sh
Admin:  user $name-admin, password in $site_dir/secrets/wp_admin_password
EOF
