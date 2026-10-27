#!/usr/bin/env bash
# Migrates an existing WordPress site from a shared hosting. The source is only read.
#   1. creates sites/<name> with new-site.sh (kept if it already exists: the script can be rerun)
#   2. downloads wp-config.php and wp-content over FTP/FTPS/SFTP (lftp in a container)
#   3. takes the table prefix from wp-config.php, then deletes it (old credentials)
#   4. checks the dump exported from phpMyAdmin and puts it in import/
#   5. starts the site (the first start imports the dump, rewrites the URLs and
#      resets the admin passwords, see wordpress/bin/wp-bootstrap) and adds it to the edge
#
# Usage: ./migrate-site.sh <name> <domain> --host <host> --user <user> --path <docroot>
#            --dump <db.sql|db.sql.gz> [--proto ftp|ftps|sftp] [--insecure-tls] [--test]
#   --path          remote directory with wp-content, e.g. /public_html
#   --proto         default ftps (explicit TLS)
#   --insecure-tls  do not verify the FTPS certificate (shared hosts with a generic one)
#   --test          self-signed certificate, no Cloudflare checks (see new-site.sh)
# The FTP password is asked at the prompt, or read from FTP_PASSWORD: never from argv.
set -Eeuo pipefail

cd "$(dirname "$0")"
. ./lib.sh

usage() {
    echo "usage: $0 <name> <domain> --host <host> --user <user> --path <docroot> --dump <file> [--proto ftp|ftps|sftp] [--insecure-tls] [--test]" >&2
    exit 2
}

[ $# -ge 2 ] || usage
name=$1 domain=$2; shift 2
host="" user="" path="" dump="" proto=ftps verify_tls=yes test_flag=()
while [ $# -gt 0 ]; do
    case "$1" in
        --host|--user|--path|--dump|--proto)
            [ $# -ge 2 ] || usage
            declare "${1#--}=$2"; shift ;;
        --insecure-tls) verify_tls=no ;;
        --test) test_flag=(--test) ;;
        *) usage ;;
    esac
    shift
done

# --- inputs ------------------------------------------------------------------
valid_site_name "$name" || die "name: lowercase letters, digits and '-' (max 31), not 'edge'"
[[ $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,253}[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] || die "invalid --host"
[[ $user =~ ^[A-Za-z0-9._@+-]{1,128}$ ]] || die "invalid --user"
[[ $path =~ ^/[A-Za-z0-9._/-]*$ ]] && [[ $path != *..* ]] || die "invalid --path (absolute, no spaces)"
path=${path%/}
case "$proto" in ftp|ftps|sftp) ;; *) die "--proto: ftp, ftps or sftp" ;; esac
[ -f "$dump" ] || die "dump not found: $dump"
[ -f images.env ] || die "images.env not found: run build.sh and copy it here"
mirror_image=$(env_value images.env MIRROR_IMAGE)
[ -n "$mirror_image" ] || die "MIRROR_IMAGE missing in images.env"

# readable dump: gzip or plain SQL
dump_cat() {
    if [[ $dump == *.gz ]]; then gzip -dc "$dump"; else cat "$dump"; fi
}
if [[ $dump == *.gz ]]; then gzip -t "$dump" || die "corrupted gzip: $dump"; fi
# the dump goes into DB_NAME: a CREATE DATABASE / USE would send it elsewhere
if { dump_cat || true; } | grep -Eqi -m1 '^(CREATE DATABASE|USE )'; then
    die "the dump contains CREATE DATABASE / USE: export the tables only from phpMyAdmin"
fi

site_dir="sites/$name"
import_dir="$site_dir/import"

# --- 1. site --------------------------------------------------------------------
if [ -e "$site_dir/html/.wp-bootstrap-done" ]; then
    die "$name is already running: remove it before migrating it again"
fi
if [ -f "$site_dir/.env" ]; then
    [ "$(env_value "$site_dir/.env" SITE_DOMAIN)" = "$domain" ] \
        || die "$site_dir exists with a different domain"
    log "$site_dir already exists: resuming"
else
    ./new-site.sh "$name" "$domain" "${test_flag[@]}" >/dev/null
    log "$site_dir created"
fi

# --- 2. download -----------------------------------------------------------------
if [ -z "${FTP_PASSWORD:-}" ]; then
    read -rsp "Password $proto for $user@$host: " FTP_PASSWORD; echo >&2
fi
log "downloading from $proto://$host$path"
# the password reaches the container through the environment, not the command line
LFTP_PASSWORD=$FTP_PASSWORD docker run --rm \
    -e LFTP_PASSWORD -e FTP_PROTO="$proto" -e FTP_HOST="$host" -e FTP_USER="$user" \
    -e FTP_PATH="$path" -e FTP_VERIFY_TLS="$verify_tls" -e OWNER="$(id -u):$(id -g)" \
    -v "$PWD/$import_dir:/import" -v "$PWD/bin/ftp-mirror.sh:/ftp-mirror.sh:ro" \
    "$mirror_image" /ftp-mirror.sh
unset FTP_PASSWORD

wp_content="$import_dir/files/wp-content"
[ -d "$wp_content/plugins" ] || [ -d "$wp_content/themes" ] \
    || die "no plugins/ or themes/ in $wp_content: check --path"

# --- 3. wp-config.php ----------------------------------------------------------------
config="$import_dir/wp-config.php"
if [ -f "$config" ]; then
    # read as text, never executed
    prefix=$(sed -n "s/^[[:space:]]*\\\$table_prefix[[:space:]]*=[[:space:]]*['\"]\([A-Za-z0-9_]*\)['\"].*/\1/p" "$config" | head -n 1)
    multisite=$(grep -Eic "define\([[:space:]]*['\"]MULTISITE['\"][[:space:]]*,[[:space:]]*true" "$config" || true)
    rm -f "$config"   # old database credentials
    [ "$multisite" = 0 ] || die "multisite installations are not supported"
    if [ -z "$prefix" ]; then
        # not a literal in wp-config.php: take it from the dump, if there is only one site
        tables=$({ dump_cat || true; } | sed -n "s/^CREATE TABLE \(IF NOT EXISTS \)\?\`\?\([A-Za-z0-9_]*\)\`\? .*/\2/p")
        prefix=$(sed -n 's/options$//p' <<< "$tables" | while read -r candidate; do
            if grep -qx "${candidate}usermeta" <<< "$tables"; then echo "$candidate"; fi
        done)
        [ -n "$prefix" ] && [ "$(wc -l <<< "$prefix")" = 1 ] \
            || die "table prefix not found in wp-config.php nor in the dump: set DB_TABLE_PREFIX in $site_dir/.env"
    fi
    sed -i "s|^DB_TABLE_PREFIX=.*|DB_TABLE_PREFIX=$prefix|" "$site_dir/.env"
fi
prefix=$(env_value "$site_dir/.env" DB_TABLE_PREFIX)
log "table prefix: $prefix"

# --- 4. dump --------------------------------------------------------------------
if ! { dump_cat || true; } | grep -Eq -m1 "CREATE TABLE (IF NOT EXISTS )?\`?${prefix}options\`?"; then
    die "no ${prefix}options table in the dump: wrong dump or wrong prefix"
fi
rm -f "$import_dir/db.sql" "$import_dir/db.sql.gz"
if [[ $dump == *.gz ]]; then target="$import_dir/db.sql.gz"; else target="$import_dir/db.sql"; fi
cp "$dump" "$target"
chmod 644 "$target"
log "dump copied to $target"

# PHP in uploads is the most common backdoor: nginx never runs it, but check it
suspicious=$(find "$wp_content/uploads" -type f \( -iname '*.php*' -o -iname '*.phtml' -o -iname '*.phar' \) 2>/dev/null || true)
if [ -n "$suspicious" ]; then
    log "WARNING: PHP files in uploads (blocked by nginx, check and delete them):"
    log "$suspicious"
fi

# --- 5. start ----------------------------------------------------------------------
if [ "${test_flag[*]}" != --test ] && [ ! -s "$site_dir/secrets/origin_cert.pem" ]; then
    log ""
    log "Files ready. Missing: Cloudflare origin certificate in $site_dir/secrets/"
    log "(origin_cert.pem, origin_key.pem, mode 0644). Then:"
    log "  ./site.sh $name up -d --wait --wait-timeout 900 && ./edge.sh"
    exit 0
fi
log "starting $name (first start: dump import, URL rewrite, password reset)"
./site.sh "$name" up -d --wait --wait-timeout 900
./edge.sh

log ""
log "Site $name migrated to https://$domain"
log "Administrators (passwords reset, set a new one with"
log "  ./site.sh $name exec updater wp --allow-root user update <login> --prompt=user_pass):"
./site.sh "$name" exec -T updater wp --allow-root user list --role=administrator --fields=ID,user_login,user_email
