#!/usr/bin/env bash
# Deploy built systems to the Pis one at a time, from GitHub Actions.
#
#   scripts/ci-deploy.sh <host>=<store path> [<host>=<store path> ...]
#
# Hosts go in the order given; the workflow passes dns2, dns1, kitchen-music,
# so the two DNS nodes are never both mid-switch. After each switch the Pi
# checks itself: its services are active, and for DNS nodes it answers both
# an internet name and a name under the local domain. A failed check rolls
# that Pi back to its previous generation and stops the run, so later hosts
# stay on what they had.
#
# Expects ssh to reach tom@<ip> with the deploy key (the workflow sets
# NIX_SSHOPTS and an ssh config). Every check runs over SSH on the Pi: the
# WireGuard peer can reach port 22 and nothing else.
set -euo pipefail

declare -A IP=( [dns1]=192.168.96.45 [dns2]=192.168.96.60 [kitchen-music]=192.168.96.157 )
declare -A SERVICES=(
  [dns1]="coredns adguardhome unbound"
  [dns2]="coredns adguardhome unbound"
  [kitchen-music]="coredns adguardhome unbound spotifyd shairport-sync"
)
DOMAIN=$(nix eval --raw --file sites/rainnworks.nix domain)
LOCAL_IP=$(nix eval --raw --file sites/rainnworks.nix localIP)

# The command is built here and run there, so expanding it locally is the point.
# shellcheck disable=SC2029
on_pi() { ssh "tom@$1" "$2"; }

healthy() {
  local host=$1 ip=${IP[$1]}
  on_pi "$ip" "systemctl is-active ${SERVICES[$host]}" >/dev/null || { echo "  services not all active"; return 1; }
  # Give the resolvers a moment to come back after a restart.
  for _ in $(seq 1 10); do
    if on_pi "$ip" "dig +short +time=2 +tries=1 @127.0.0.1 cloudflare.com | grep -q ." &&
       [ "$(on_pi "$ip" "dig +short +time=2 +tries=1 @127.0.0.1 deploy-check.$DOMAIN")" = "$LOCAL_IP" ]; then
      return 0
    fi
    sleep 3
  done
  echo "  DNS check failed: cloudflare.com or deploy-check.$DOMAIN"
  return 1
}

for arg in "$@"; do
  host=${arg%%=*} path=${arg#*=} ip=${IP[${arg%%=*}]}
  echo "▸ $host ($ip)"

  if [ "$(on_pi "$ip" 'readlink /run/current-system')" = "$path" ]; then
    echo "  already running $path"
    continue
  fi

  echo "  copying closure"
  nix copy --no-check-sigs --to "ssh-ng://tom@$ip" "$path"

  echo "  switching"
  if on_pi "$ip" "sudo nix-env -p /nix/var/nix/profiles/system --set '$path' && sudo '$path/bin/switch-to-configuration' switch" &&
     healthy "$host"; then
    echo "  healthy"
  else
    echo "  rolling $host back"
    on_pi "$ip" "sudo nix-env -p /nix/var/nix/profiles/system --rollback && sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch"
    echo "::error::$host failed to switch or failed its health check, and was rolled back. Later hosts were not deployed."
    exit 1
  fi
done
