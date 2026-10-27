# shellcheck shell=bash
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

# Address block of a site: NET_PREFIX.SITE_NET.0/24 (default prefix 10.200), split by
# compose.yaml into four /26: edge .0, web .64, data .128, egress .192
site_net_prefix() {
    local env_file="sites/$1/.env" prefix net
    prefix=$(env_value "$env_file" NET_PREFIX)
    prefix=${prefix:-10.200}
    net=$(env_value "$env_file" SITE_NET)
    [[ $prefix =~ ^[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "$env_file: invalid NET_PREFIX"
    [[ $net =~ ^[0-9]{1,3}$ ]] && (( net >= 1 && net <= 254 )) || die "$env_file: SITE_NET must be 1-254"
    echo "$prefix.$net"
}

# First SITE_NET not used by the other sites
free_site_net() {
    local used net
    used=$(sed -n 's/^SITE_NET=//p' sites/*/.env 2>/dev/null || true)
    for net in $(seq 1 254); do
        grep -qx "$net" <<< "$used" || { echo "$net"; return 0; }
    done
    die "no free SITE_NET left (1-254)"
}

# Internal network between the site nginx and the edge proxy, one per site,
# created here because the edge joins it too (the site compose declares it external)
ensure_edge_network() {
    local network="$1_edge" subnet
    if ! docker network inspect "$network" >/dev/null 2>&1; then
        subnet="$(site_net_prefix "$1").0/26"
        docker network create --internal --subnet "$subnet" \
            --label "wp.site=$1" "$network" >/dev/null
        log "network $network created ($subnet)"
    fi
}

# DNS for one-off containers that reach the Internet (same defaults as compose.yaml)
container_dns() {
    printf -- '--dns %s --dns %s' "${CONTAINER_DNS_1:-1.1.1.1}" "${CONTAINER_DNS_2:-9.9.9.9}"
}
