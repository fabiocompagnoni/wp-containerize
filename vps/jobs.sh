#!/usr/bin/env bash
# Scheduled jobs of the sites, started by the systemd timers in systemd/:
#   ./jobs.sh cron [<site>...]     scheduled tasks of the running sites (every 5 minutes):
#                                  due wp-cron events, or the vtiger cron (vtigercron.php)
#   ./jobs.sh update [<site>...]   updates of the WordPress sites with backup, checks and
#                                  rollback (daily), one site at a time, see wordpress/bin/wp-update;
#                                  vtiger is updated by hand with its patches
# Without site names every site in sites/ is processed. Exit status 1 if any site failed.
set -Eeuo pipefail

cd "$(dirname "$0")"
. ./lib.sh

all_sites() {
    local env_file
    for env_file in sites/*/.env; do
        [ -f "$env_file" ] && basename "$(dirname "$env_file")"
    done
}

is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1-nginx" 2>/dev/null)" = true ]
}

site_type() {
    local type
    type=$(env_value "sites/$1/.env" SITE_TYPE)
    echo "${type:-wordpress}"
}

# vtiger cron (workflows, reminders, mail converter), as www-data
vtiger_cron() {
    ./site.sh "$1" exec -T -u www-data -w /var/www/html app \
        timeout "$CRON_EVENT_TIMEOUT" php -f vtigercron.php
}

# wp-cli in the wordpress container, as www-data: files written by cron events
# (thumbnails, caches) keep the right owner
site_wp() {
    local name=$1
    shift
    ./site.sh "$name" exec -T -u www-data -e WP_CLI_CACHE_DIR=/tmp/wp-cli-cache wordpress wp "$@"
}

# the same with a time limit in seconds
site_timeout_wp() {
    local name=$1 seconds=$2
    shift 2
    ./site.sh "$name" exec -T -u www-data -e WP_CLI_CACHE_DIR=/tmp/wp-cli-cache wordpress \
        timeout "$seconds" wp "$@"
}

CRON_EVENT_TIMEOUT=${CRON_EVENT_TIMEOUT:-240}

cmd_cron() {
    local name hook due failed=()
    for name in "$@"; do
        is_running "$name" || continue
        if [ "$(site_type "$name")" = vtiger ]; then
            vtiger_cron "$name" >/dev/null || { log "$name: vtiger cron failed"; failed+=("$name"); }
            continue
        fi
        due=$(site_wp "$name" cron event list --fields=hook,time --format=csv \
            | awk -F, -v now="$(date +%s)" 'NR > 1 && $2 <= now { print $1 }' | sort -u) \
            || { failed+=("$name"); continue; }
        # one process per hook: a broken plugin event (fatal error) does not stop the others.
        # wp-cli has no PHP time limit: cap every event below the 5-minute timer interval
        for hook in $due; do
            site_timeout_wp "$name" "$CRON_EVENT_TIMEOUT" cron event run "$hook" --quiet \
                || { log "$name: cron event $hook failed or timed out"; failed+=("$name:$hook"); }
        done
    done
    [ ${#failed[@]} -eq 0 ] || die "wp-cron failed for: ${failed[*]}"
}

cmd_update() {
    local name failed=()
    exec 9>.jobs-update.lock
    flock -n 9 || die "another update is running"
    for name in "$@"; do
        if ! is_running "$name"; then log "$name: not running, skipped"; continue; fi
        [ "$(site_type "$name")" = wordpress ] || continue
        log "$name: updating"
        ./site.sh "$name" run --rm updater || failed+=("$name")
    done
    [ ${#failed[@]} -eq 0 ] || die "update failed or rolled back for: ${failed[*]}"
}

[ $# -ge 1 ] || die "usage: $0 cron|update [<site>...]"
job=$1; shift
names=("$@")
if [ ${#names[@]} -eq 0 ]; then mapfile -t names < <(all_sites); fi
for name in "${names[@]}"; do
    valid_site_name "$name" || die "invalid site name: $name"
done

case "$job" in
    cron) cmd_cron "${names[@]}" ;;
    update) cmd_update "${names[@]}" ;;
    *) die "usage: $0 cron|update [<site>...]" ;;
esac
