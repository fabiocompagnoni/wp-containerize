#!/usr/bin/env bash
# Migrates a vtiger CRM from an archive of its folder and a database dump.
#   1. creates sites/<name> with new-site.sh --type vtiger (kept if it already exists)
#   2. extracts the main vtiger install into html/ (bin/vtiger-extract.sh, in a container)
#   3. adapts config.inc.php: database of the site (password read from the secret, never
#      written in the file), site_URL and root_directory of the new host
#   4. checks the dump and puts it in import/, normalised as in migrate-site.sh
#   5. starts the site (the first start imports the dump, see vtiger/bin/vtiger-bootstrap)
#      and adds it to the edge
#
# Usage: ./migrate-vtiger.sh <name> <domain> --files <archive.tar[.gz]|.zip> --dump <db.sql[.gz]> [--test]
#   --test  self-signed certificate, no Cloudflare checks (see new-site.sh)
set -Eeuo pipefail

cd "$(dirname "$0")"
. ./lib.sh

usage() {
    echo "usage: $0 <name> <domain> --files <archive> --dump <db.sql[.gz]> [--test]" >&2
    exit 2
}

[ $# -ge 2 ] || usage
name=$1 domain=$2; shift 2
files="" dump="" test_flag=()
while [ $# -gt 0 ]; do
    case "$1" in
        --files) [ $# -ge 2 ] || usage; files=$2; shift ;;
        --dump) [ $# -ge 2 ] || usage; dump=$2; shift ;;
        --test) test_flag=(--test) ;;
        *) usage ;;
    esac
    shift
done

# --- inputs ------------------------------------------------------------------
valid_site_name "$name" || die "name: lowercase letters, digits and '-' (max 31), not 'edge'"
[ -f "$files" ] || die "archive not found: $files"
[ -f "$dump" ] || die "dump not found: $dump"
[ -f images.env ] || die "images.env not found: run build.sh and copy it here"

dump_cat() {
    if [[ $dump == *.gz ]]; then gzip -dc "$dump"; else cat "$dump"; fi
}
if [[ $dump == *.gz ]]; then gzip -t "$dump" || die "corrupted gzip: $dump"; fi
use_count=$({ dump_cat || true; } | grep -Eic '^USE ' || true)
[ "${use_count:-0}" -le 1 ] || die "the dump contains $use_count databases: export only the CRM database"
{ dump_cat || true; } | grep -Eq -m1 'CREATE TABLE (IF NOT EXISTS )?`?vtiger_version`?' \
    || die "no vtiger_version table in the dump: is it the vtiger database?"

site_dir="sites/$name"
html="$site_dir/html"

# --- 1. site --------------------------------------------------------------------
if [ -e "$html/.vtiger-bootstrap-done" ]; then
    die "$name is already running: remove it before migrating it again"
fi
if [ -f "$site_dir/.env" ]; then
    [ "$(env_value "$site_dir/.env" SITE_DOMAIN)" = "$domain" ] \
        || die "$site_dir exists with a different domain"
    [ "$(env_value "$site_dir/.env" SITE_TYPE)" = vtiger ] || die "$site_dir is not a vtiger site"
    log "$site_dir already exists: resuming"
else
    ./new-site.sh "$name" "$domain" --type vtiger "${test_flag[@]}" >/dev/null
    log "$site_dir created"
fi

# --- 2. files --------------------------------------------------------------------
log "extracting vtiger from $files"
archive_dir=$(cd "$(dirname "$files")" && pwd)
docker run --rm -e ARCHIVE="$(basename "$files")" -e OWNER="$(id -u):$(id -g)" \
    -v "$archive_dir:/source:ro" -v "$PWD/$html:/html" \
    -v "$PWD/bin/vtiger-extract.sh:/vtiger-extract.sh:ro" \
    --entrypoint /bin/sh "$(env_value images.env WORDPRESS_IMAGE_REF)" /vtiger-extract.sh
[ -f "$html/vtigerversion.php" ] && [ -f "$html/config.inc.php" ] \
    || die "no vtigerversion.php / config.inc.php in $html"
version=$(sed -n "s/^\$vtiger_current_version *= *'\([^']*\)'.*/\1/p" "$html/vtigerversion.php")
log "vtiger $version"

# --- 3. config.inc.php -----------------------------------------------------------
# read as text and changed only in these lines; the old database credentials go away
db_name=$(env_value "$site_dir/.env" DB_NAME)
db_user=$(env_value "$site_dir/.env" DB_USER)
config="$html/config.inc.php"
set_config() {
    local pattern=$1 line=$2
    grep -Eq "^[[:space:]]*$pattern" "$config" || die "config.inc.php: line not found: $pattern"
    # the replacement has no "|" or "&": a fixed text for sed
    sed -i -E "s|^[[:space:]]*$pattern.*|$line|" "$config"
}
set_config "\\\$dbconfig\['db_server'\]" "\$dbconfig['db_server'] = 'db';"
set_config "\\\$dbconfig\['db_port'\]" "\$dbconfig['db_port'] = ':3306';"
set_config "\\\$dbconfig\['db_username'\]" "\$dbconfig['db_username'] = '$db_user';"
set_config "\\\$dbconfig\['db_password'\]" "\$dbconfig['db_password'] = trim(file_get_contents('/run/secrets/db_password'));"
set_config "\\\$dbconfig\['db_name'\]" "\$dbconfig['db_name'] = '$db_name';"
set_config "\\\$site_URL" "\$site_URL = 'https://$domain/';"
set_config "\\\$root_directory" "\$root_directory = '/var/www/html/';"
log "config.inc.php adapted (database $db_name, https://$domain/)"

# --- 4. dump ----------------------------------------------------------------------
mkdir -p "$site_dir/import"
target="$site_dir/import/db.sql.gz"
rm -f "$site_dir/import/db.sql" "$target"
dump_cat \
    | sed -E -e '/^(CREATE DATABASE|USE )/Id' \
             -e "s/DEFAULT x AS \`([0-9A-Fa-f]+)\`/DEFAULT x'\1'/g" \
    | gzip -c > "$target"
chmod 644 "$target"
log "dump copied to $target"

# --- 5. start ----------------------------------------------------------------------
if [ "${test_flag[*]}" != --test ] && [ ! -s "$site_dir/secrets/origin_cert.pem" ]; then
    log ""
    log "Files ready. Missing: Cloudflare origin certificate in $site_dir/secrets/"
    log "(origin_cert.pem, origin_key.pem, mode 0644). Then:"
    log "  ./site.sh $name up -d --wait --wait-timeout 900 && ./edge.sh"
    exit 0
fi
log "starting $name (first start: dump import)"
./site.sh "$name" up -d --wait --wait-timeout 900
./edge.sh
log ""
log "CRM $name migrated to https://$domain/"
