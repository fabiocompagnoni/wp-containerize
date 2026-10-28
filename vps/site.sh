#!/usr/bin/env bash
# docker compose for one site, with images.env and the site settings. The compose file
# depends on SITE_TYPE in the site .env: wordpress (default, compose.yaml) or vtiger
# (vtiger/compose.yaml); paths in both are relative to this directory.
# Usage: ./site.sh <site> <docker compose arguments>
#   ./site.sh esempio up -d          ./site.sh esempio logs -f wordpress
#   ./site.sh esempio exec wordpress wp --allow-root plugin list
set -Eeuo pipefail

cd "$(dirname "$0")"
. ./lib.sh

[ $# -ge 2 ] || die "usage: $0 <site> <docker compose arguments>"
name=$1; shift
valid_site_name "$name" || die "invalid site name: $name"
env_file="sites/$name/.env"
[ -f "$env_file" ] || die "$env_file not found (create the site with new-site.sh or migrate-site.sh)"
[ "$(env_value "$env_file" SITE_NAME)" = "$name" ] || die "SITE_NAME in $env_file is not $name"
[ -f images.env ] || die "images.env not found: run build.sh and copy it here"

case "$(env_value "$env_file" SITE_TYPE)" in
    ""|wordpress) compose_file=compose.yaml ;;
    vtiger) compose_file=vtiger/compose.yaml ;;
    *) die "SITE_TYPE in $env_file: wordpress or vtiger" ;;
esac

if [ "$1" = up ]; then ensure_edge_network "$name"; fi
exec docker compose -f "$compose_file" --project-directory . \
    --env-file images.env --env-file "$env_file" "$@"
