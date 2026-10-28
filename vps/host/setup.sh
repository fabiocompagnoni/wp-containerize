#!/usr/bin/env bash
# Prepares the VPS host (Ubuntu with Docker already installed). Run as root on the VPS;
# it can be run again: every step checks the current state first.
#   - SSH: keys only (no passwords), root only with a key
#   - swap file (default 2G), low swappiness: margin against out-of-memory kills
#   - Docker: log rotation, live-restore (containers keep running while dockerd restarts)
#   - unattended-upgrades: security updates with automatic reboot at night if needed
#   - /srv/wp: where the vps/ directory of the repository is copied, with the links
#     ~/wp -> /srv/wp and ~/siti -> /srv/wp/sites in the home of root
# The firewall is the Hetzner Cloud Firewall (see README): Docker bypasses ufw for
# published ports, so a host firewall would not protect the edge.
#
# Usage: ./host/setup.sh [--swap <size, e.g. 2G>]
set -Eeuo pipefail

cd "$(dirname "$0")"

log() { printf '[setup] %s\n' "$*" >&2; }
die() { printf '[setup] error: %s\n' "$*" >&2; exit 1; }

swap_size=2G
case "${1:-}" in
    "") ;;
    --swap) [[ ${2:-} =~ ^[0-9]+[MG]$ ]] || die "--swap: size like 2G"; swap_size=$2 ;;
    *) die "usage: $0 [--swap <size>]" ;;
esac

[ "$(id -u)" = 0 ] || die "run as root"
command -v docker >/dev/null || die "install Docker first"

# --- SSH -------------------------------------------------------------------
sshd_conf=/etc/ssh/sshd_config.d/10-wp-hardening.conf
cat > "$sshd_conf.new" <<'EOF'
# keys only: no passwords, root only with a key
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
if ! cmp -s "$sshd_conf.new" "$sshd_conf"; then
    mv "$sshd_conf.new" "$sshd_conf"
    sshd -t || { rm -f "$sshd_conf"; die "invalid sshd configuration, change removed"; }
    systemctl reload ssh
    log "SSH: passwords disabled"
else
    rm -f "$sshd_conf.new"
fi

# --- swap ------------------------------------------------------------------
if ! swapon --show=NAME --noheadings | grep -q .; then
    fallocate -l "$swap_size" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "swap: $swap_size"
fi
echo 'vm.swappiness = 10' > /etc/sysctl.d/90-wp-swap.conf
sysctl -q -p /etc/sysctl.d/90-wp-swap.conf

# --- Docker ----------------------------------------------------------------
if ! cmp -s daemon.json /etc/docker/daemon.json; then
    install -m 0644 daemon.json /etc/docker/daemon.json
    systemctl restart docker
    log "Docker: daemon.json installed"
fi

# --- security updates --------------------------------------------------------
cat > /etc/apt/apt.conf.d/52wp-unattended <<'EOF'
// security updates every day; reboot at night only when an update requires it
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1

# --- tools and directory -----------------------------------------------------
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync curl openssl unzip >/dev/null
install -d -m 0750 /srv/wp /srv/wp/sites

# shortcuts visible with "ls" right after the SSH login
ln -sfn /srv/wp /root/wp
ln -sfn /srv/wp/sites /root/siti

log "done"
