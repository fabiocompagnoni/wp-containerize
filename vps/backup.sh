#!/usr/bin/env bash
# Backups of every site with restic (in a container), encrypted, outside the VPS.
# For each site one snapshot tagged site:<name> with the database dump, html/ (without
# caches), .env and secrets/. Then the old snapshots are pruned (BACKUP_KEEP_*).
#
# Usage: ./backup.sh init              SSH key and repository password, then the repository
#        ./backup.sh run [<site>...]   backup of all the sites (or only the ones given)
#        ./backup.sh restic <args>     any restic command, e.g. snapshots --tag site:esempio
#                                      (restore --target /restore writes in backup/restore/)
# Settings in backup.env (see backup.env.example). Keys and password in backup/ (0700):
# keep a copy of backup/restic_password elsewhere, without it the backups cannot be read.
set -Eeuo pipefail

cd "$(dirname "$0")"
. ./lib.sh

[ -f backup.env ] || die "backup.env not found: copy backup.env.example"
set -a; . ./backup.env; set +a
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY in backup.env}"
restic_image=$(env_value images.env RESTIC_IMAGE)
[ -n "$restic_image" ] || die "RESTIC_IMAGE missing in images.env"

state=$PWD/backup
key=$state/id_ed25519
password_file=$state/restic_password
dumps=$state/dumps

# restic in a container: sites read-only, dumps read-only, restores in backup/restore
restic_() {
    local args=(--rm -i --hostname "$(hostname)"
        -e RESTIC_REPOSITORY -e RESTIC_PASSWORD_FILE=/backup/restic_password
        -v "$state:/backup" -v "$PWD/sites:/sites:ro" -v "$dumps:/dumps:ro"
        -v "$state/restore:/restore")
    local options=()
    case "$RESTIC_REPOSITORY" in
        sftp:*)
            local target=${RESTIC_REPOSITORY#sftp:}
            target=${target%%:*}
            options=(-o "sftp.command=ssh -p ${SSH_PORT:-22} -i /backup/id_ed25519 -o UserKnownHostsFile=/backup/known_hosts -o StrictHostKeyChecking=accept-new $target -s sftp")
            ;;
        /*) args+=(-v "$RESTIC_REPOSITORY:$RESTIC_REPOSITORY") ;;
    esac
    docker run "${args[@]}" "$restic_image" "${options[@]}" "$@"
}

notify() {
    [ -n "${BACKUP_WEBHOOK_URL:-}" ] || return 0
    curl -fsS --max-time 15 -H 'Content-Type: application/json' \
        -d "{\"host\":\"$(hostname)\",\"event\":\"backup failed\",\"sites\":\"$1\"}" \
        "$BACKUP_WEBHOOK_URL" >/dev/null || log "webhook not reachable"
}

cmd_init() {
    umask 077
    mkdir -p "$state" "$state/restore" "$dumps"
    chmod 700 "$state"
    if [ ! -f "$key" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "wp-backup@$(hostname)" -f "$key"
    fi
    if [ ! -f "$password_file" ]; then
        openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40 > "$password_file"
        log "repository password in $password_file: SAVE A COPY ELSEWHERE"
    fi
    if [[ $RESTIC_REPOSITORY == sftp:* ]]; then
        log "public key to add to the Storage Box (.ssh/authorized_keys):"
        cat "$key.pub"
        read -rp "Press Enter when the key is on the Storage Box... " _
    fi
    if restic_ cat config >/dev/null 2>&1; then
        log "repository already initialised"
    else
        restic_ init
    fi
}

# dump of the site database into dumps/<site>.sql, with the site DB user
dump_db() {
    local name=$1
    ./site.sh "$name" exec -T db sh -c \
        'MYSQL_PWD="$(cat /run/secrets/db_password)" exec mariadb-dump --single-transaction --quick --no-tablespaces --routines --triggers -u"$MARIADB_USER" "$MARIADB_DATABASE"' \
        > "$dumps/$name.sql"
}

backup_site() {
    local name=$1
    dump_db "$name" || { log "$name: database dump failed"; return 1; }
    restic_ backup --quiet --tag "site:$name" \
        --exclude "/sites/$name/html/wp-content/cache" \
        --exclude "/sites/$name/html/cache" \
        --exclude "/sites/$name/html/logs" \
        --exclude "/sites/$name/import" \
        "/sites/$name" "/dumps/$name.sql" \
        || { log "$name: restic backup failed"; return 1; }
    log "$name: backup done"
}

cmd_run() {
    local names=("$@") failed=() name
    if [ ${#names[@]} -eq 0 ]; then
        for env_file in sites/*/.env; do
            [ -f "$env_file" ] && names+=("$(basename "$(dirname "$env_file")")")
        done
    fi
    [ -f "$password_file" ] || die "run ./backup.sh init first"

    # one run at a time
    exec 9>"$state/.lock"
    flock -n 9 || die "another backup is running"
    umask 077
    mkdir -p "$dumps" "$state/restore"
    trap 'rm -f "$dumps"/*.sql' EXIT

    for name in "${names[@]}"; do
        valid_site_name "$name" || { log "skipped invalid site name $name"; continue; }
        # a stopped site (prepared, not started yet) has no new data and no database to dump
        if [ "$(docker inspect -f '{{.State.Running}}' "$name-db" 2>/dev/null)" != true ]; then
            log "$name: database not running, skipped"
            continue
        fi
        backup_site "$name" || failed+=("$name")
        rm -f "$dumps/$name.sql"
    done

    restic_ forget --quiet --prune --group-by host,tags \
        --keep-daily "${BACKUP_KEEP_DAILY:-7}" --keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" \
        --keep-monthly "${BACKUP_KEEP_MONTHLY:-6}" \
        || failed+=("(prune)")

    if [ ${#failed[@]} -gt 0 ]; then
        notify "${failed[*]}"
        die "backup failed for: ${failed[*]}"
    fi
    log "backup completed: ${names[*]}"
}

case "${1:-}" in
    init) cmd_init ;;
    run) shift; cmd_run "$@" ;;
    restic) shift; mkdir -p "$state/restore" "$dumps"; restic_ "$@" ;;
    *) die "usage: $0 init | run [<site>...] | restic <args>" ;;
esac
