#!/usr/bin/env bash
# Copies this directory (scripts, compose files, images.env) to /srv/wp on the VPS, without
# what lives only there: sites/, backup/, incoming/, backup.env, the generated edge files.
# Files are extracted as root with normal permissions (umask): nothing else on the VPS
# changes owner or mode. Never run chown/chmod -R on /srv/wp: sites/ holds the files of
# the sites, owned by the users of the containers (www-data).
#
# Usage: ./host/push.sh <user@host> [ssh options...]
#   e.g. ./host/push.sh root@203.0.113.10 -i ~/.ssh/vps_key
set -Eeuo pipefail

cd "$(dirname "$0")/.."

[ $# -ge 1 ] || { echo "usage: $0 <user@host> [ssh options...]" >&2; exit 2; }
target=$1
shift

[ -f images.env ] || { echo "error: images.env not found: run build.sh" >&2; exit 1; }
if grep -q '_REF=local/' images.env; then
    echo "error: images.env points to local images (build.sh --local): run build.sh" >&2
    exit 1
fi

tar -C . \
    --exclude=./sites --exclude=./backup --exclude=./incoming \
    --exclude=./backup.env --exclude=./build.local.env --exclude=./.jobs-update.lock \
    --exclude=./edge/conf.d --exclude=./edge/sites.yaml --exclude=./edge/origin-pull-ca.pem \
    -czf - . \
    | ssh "$@" "$target" \
        'install -d /srv/wp && tar -C /srv/wp -xzf - --no-same-owner --no-same-permissions && chmod 0750 /srv/wp'
echo "copied to $target:/srv/wp"
