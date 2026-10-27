#!/usr/bin/env bash
# Removes a site: containers, volumes (database, backups, cache), files in sites/<name>,
# its vhost and network on the edge. Irreversible: asks to type the site name.
# Usage: ./remove-site.sh <name>
set -Eeuo pipefail

cd "$(dirname "$0")"
. ./lib.sh

[ $# -eq 1 ] || die "usage: $0 <name>"
name=$1
valid_site_name "$name" || die "invalid site name: $name"
[ -d "sites/$name" ] || die "sites/$name not found"

read -rp "Delete $name with its database and files? Type the name to confirm: " answer
[ "$answer" = "$name" ] || die "not confirmed"

if [ -f "sites/$name/.env" ]; then ./site.sh "$name" down -v; fi
# html/ and import/ contain files created by the containers (www-data, root)
docker run --rm -v "$PWD/sites:/sites" "$(env_value images.env MIRROR_IMAGE)" rm -rf "/sites/$name"
./edge.sh                                   # edge leaves the site network first
docker network rm "${name}_edge" >/dev/null 2>&1 || true
log "$name removed"
