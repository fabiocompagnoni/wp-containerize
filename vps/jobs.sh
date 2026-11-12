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
        # php sites: no wp-cron (scheduled tasks of the application are set up per site)
        [ "$(site_type "$name")" != php ] || continue
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
        # only WordPress is updated automatically: vtiger and php sites (e.g. PrestaShop,
        # with its Update Assistant) are updated by hand, after a backup
        [ "$(site_type "$name")" = wordpress ] || continue
        if ! is_running "$name"; then log "$name: not running, skipped"; continue; fi
        # backup on the Storage Box first: without it no update (the updater keeps only
        # a temporary local copy for its own rollback)
        if ! ./backup.sh run "$name"; then
            log "$name: backup failed, update skipped"; failed+=("$name"); continue
        fi
        log "$name: updating"
        ./site.sh "$name" run --rm updater </dev/null || failed+=("$name")
        # graceful reload of PHP-FPM (PID 1 of the wordpress container): after a rollback
        # OPcache may still serve the compiled files of the updated, removed code (error 500)
        ./site.sh "$name" exec -T wordpress kill -USR2 1 \
            || { log "$name: PHP-FPM reload failed"; failed+=("$name"); }
        refresh_pages "$name" || log "$name: page cache not refreshed"
    done
    [ ${#failed[@]} -eq 0 ] || die "update failed or rolled back for: ${failed[*]}"
}

# After an update (or a rollback) the cached pages may point to files that no longer
# exist: Elementor deletes its generated CSS when it is updated and rebuilds it only when
# PHP renders a page, which never happens while the page comes from the cache (the site
# shows without layout). Rebuild Elementor's CSS, empty the page cache, render the home.
refresh_pages() {
    local name=$1 host
    if site_wp "$name" plugin is-active elementor 2>/dev/null; then
        site_wp "$name" elementor flush-css >/dev/null 2>&1 || log "$name: Elementor CSS not flushed"
    fi
    site_wp "$name" eval 'do_action("rt_nginx_helper_purge_all");' >/dev/null 2>&1 || return 1
    host=$(env_value "sites/$name/.env" SITE_URL); host=${host#*://}; host=${host%%/*}
    [ -n "$host" ] || host=$(env_value "sites/$name/.env" SITE_DOMAIN)
    ./site.sh "$name" exec -T nginx curl -fsS -o /dev/null --max-time 60 \
        -H "Host: $host" -H "X-Forwarded-Proto: https" http://127.0.0.1/ >/dev/null 2>&1
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
