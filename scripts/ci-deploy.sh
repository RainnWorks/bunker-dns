#!/usr/bin/env bash
# Deploy built systems to the Pis one at a time, from Tower's runner.
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
# NIX_SSHOPTS and an ssh config). SYSTEMS_STORE, if set, is where the built
# systems are (the workflow's artifact, a file:// store); otherwise they
# must already be in the local Nix store.
#
# The whole closure goes from here to the Pi over the LAN; the Pi doesn't
# download from cache.nixos.org itself. With --substitute-on-destination a
# Pi Zero 2 W (about 450 MB) ran Nix's many parallel downloads and
# decompressions, ran out of memory mid-copy and stopped answering anything
# for four hours (2026-11-25). Here the Pi only unpacks one stream; the
# artifact holds the full closure anyway.
#
# Every ssh, including nix copy's, gives up on a Pi that stops answering
# (ServerAlive*), and every remote command and copy has a time limit, so a
# hung Pi fails the run instead of holding it until GitHub's 6 hours.
set -euo pipefail

declare -A IP=( [dns1]=192.168.96.45 [dns2]=192.168.96.60 [kitchen-music]=192.168.96.157 )
declare -A SERVICES=(
  [dns1]="coredns adguardhome unbound"
  [dns2]="coredns adguardhome unbound"
  [kitchen-music]="coredns adguardhome unbound spotifyd shairport-sync"
)
DOMAIN=$(nix eval --raw --file sites/rainnworks.nix domain)
LOCAL_IP=$(nix eval --raw --file sites/rainnworks.nix localIP)

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
export NIX_SSHOPTS="${NIX_SSHOPTS:-} ${SSH_OPTS[*]}"
ON_PI_TIMEOUT=600 # seconds; a switch restarts services, so allow some minutes
COPY_TIMEOUT=1800 # seconds; a new release's closure is about 1 GB over USB Ethernet

# The command is built here and run there, so expanding it locally is the point.
# shellcheck disable=SC2029
on_pi() { timeout "$ON_PI_TIMEOUT" ssh "${SSH_OPTS[@]}" "tom@$1" "$2"; }

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
  if ! timeout "$COPY_TIMEOUT" nix copy --no-check-sigs \
    ${SYSTEMS_STORE:+--from "$SYSTEMS_STORE"} --to "ssh-ng://tom@$ip" "$path"; then
    echo "::error::Copying to $host failed or took over $((COPY_TIMEOUT / 60)) minutes. Nothing was switched; $host and later hosts keep what they had."
    exit 1
  fi

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
