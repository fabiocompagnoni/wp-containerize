# Shared by the scripts in this directory (sourced, not executed).

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

valid_site_name() {
    [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] && [ "$1" != edge ]
}

# Value of KEY in an env file, without sourcing it
env_value() {
    sed -n "s/^$2=//p" "$1" | tail -n 1
}

# Internal network between the site nginx and the edge proxy, one per site
ensure_edge_network() {
    local network="$1_edge"
    if ! docker network inspect "$network" >/dev/null 2>&1; then
        docker network create --internal "$network" >/dev/null
        log "network $network created"
    fi
}
