#!/usr/bin/env bash
# Deploy built systems to the Pis one at a time, from Tower's runner.
#
#   scripts/ci-deploy.sh <host>=<store path> [<host>=<store path> ...]
#
# Hosts go in the order given; the workflow passes dns2, dns1, kitchen-music.
#
# dns1 and dns2 share two floating DNS addresses (keepalived, see
# modules/dns/failover.nix); each holds its own while both are healthy. A DNS
# Pi is deployed blue-green, so DNS never stops:
#
#   1. Check the peer is healthy and not drained.
#   2. Drain this Pi: its floating address moves to the peer. Check the peer
#      holds both and both answer.
#   3. Copy the new system, make it the boot default, reboot.
#   4. Check it came back on the new system and kernel, its services are
#      active and it answers DNS on its own address.
#   5. Undrain it, and check it holds its floating address again and answers
#      on it.
#
# If 4 or 5 fails, the Pi goes back to its previous generation (rebooting into
# it if the kernel differs) and stays drained, so the peer keeps both
# addresses; the run stops. Undrain it by hand once it's fixed:
# `sudo rm /var/lib/keepalived/drained`.
#
# kitchen-music has no floating address: it is switched live, checked, and
# rolled back if the check fails, then the run stops.
#
# A Pi already running its new system is skipped, unless an earlier run left
# it drained: then it is checked and undrained. A drained DNS Pi goes first.
#
# Expects ssh to reach tom@<ip> with the deploy key (the workflow sets
# NIX_SSHOPTS and an ssh config). SYSTEMS_STORE, if set, is where the built
# systems are (the workflow's artifact, a file:// store); otherwise they
# must already be in the local Nix store. Each Pi fetches what it can from
# cache.nixos.org itself, so only what's ours crosses the LAN.
set -euo pipefail

declare -A IP=( [dns1]=192.168.96.45 [dns2]=192.168.96.60 [kitchen-music]=192.168.96.157 )
declare -A PEER=( [dns1]=dns2 [dns2]=dns1 )
declare -A SERVICES=(
  [dns1]="coredns adguardhome unbound keepalived"
  [dns2]="coredns adguardhome unbound keepalived"
  [kitchen-music]="coredns adguardhome unbound spotifyd shairport-sync"
)
DOMAIN=$(nix eval --raw --file sites/rainnworks.nix domain)
LOCAL_IP=$(nix eval --raw --file sites/rainnworks.nix localIP)
declare -A VIP=(
  [dns1]=$(nix eval --raw --file sites/rainnworks.nix vips.dns1)
  [dns2]=$(nix eval --raw --file sites/rainnworks.nix vips.dns2)
)
DRAIN=/var/lib/keepalived/drained
PROFILE=/nix/var/nix/profiles/system

# The command is built here and run there, so expanding it locally is the point.
# shellcheck disable=SC2029
on_pi() { ssh "tom@$1" "$2"; }

# Polls a check until it passes or `tries` runs out, 3 s apart.
retry() {
  local tries=$1; shift
  for _ in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    sleep 3
  done
  return 1
}

# Asked from host's Pi, the local test name at addr gives LOCAL_IP.
answers() {
  local from=$1 addr=$2
  [ "$(on_pi "${IP[$from]}" "dig +short +time=2 +tries=1 @$addr deploy-check.$DOMAIN" 2>/dev/null)" = "$LOCAL_IP" ]
}

holds() { on_pi "${IP[$1]}" "ip -4 -o addr show | grep -qF ' inet $2/'" 2>/dev/null; }
drained() { on_pi "${IP[$1]}" "test -e $DRAIN"; }
drain() { on_pi "${IP[$1]}" "sudo mkdir -p ${DRAIN%/*} && sudo touch $DRAIN"; }
undrain() { on_pi "${IP[$1]}" "sudo rm -f $DRAIN"; }
has_keepalived() { on_pi "${IP[$1]}" "systemctl cat keepalived.service" >/dev/null 2>&1; }
boot_id() { on_pi "${IP[$1]}" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null; }

# The Pi's own services are active and it resolves an internet name and a
# name under the local domain.
healthy() {
  local host=$1 ip=${IP[$1]} services=${SERVICES[$1]}
  # A system from before keepalived (a rollback during the first rollout).
  if ! has_keepalived "$host"; then services=${services/ keepalived/}; fi
  retry 20 on_pi "$ip" "systemctl is-active $services" >/dev/null ||
    { echo "  services not all active: $services: $(on_pi "$ip" "systemctl is-active $services" | tr '\n' ' ')"; return 1; }
  # Give the resolvers a moment to come back after a restart.
  if ! retry 10 on_pi "$ip" "dig +short +time=2 +tries=1 @127.0.0.1 cloudflare.com | grep -q ." ||
     ! retry 10 answers "$host" 127.0.0.1; then
    echo "  DNS check failed: cloudflare.com or deploy-check.$DOMAIN"
    return 1
  fi
}

# Reboots the Pi and waits until it is back with a new boot ID, up to 10 min.
reboot_and_wait() {
  local host=$1 ip=${IP[$1]} before now deadline=$((SECONDS + 600))
  before=$(boot_id "$host") || { echo "  can't read $host's boot ID"; return 1; }
  echo "  rebooting"
  on_pi "$ip" "sudo systemctl reboot" || true
  while [ $SECONDS -lt $deadline ]; do
    sleep 10
    now=$(boot_id "$host" || true)
    if [ -n "$now" ] && [ "$now" != "$before" ]; then
      # Let boot finish before anything is checked.
      on_pi "$ip" "timeout 300 systemctl is-system-running --wait" >/dev/null 2>&1 || true
      return 0
    fi
  done
  echo "  $host did not come back within 10 minutes"
  return 1
}

# A DNS Pi after its reboot: on the new system and kernel, services up, and
# answering on its own address, asked from the peer.
dns_pi_healthy() {
  local host=$1 path=$2 ip=${IP[$1]} peer=${PEER[$1]}
  local current booted kernel new_kernel
  current=$(on_pi "$ip" "readlink /run/current-system")
  booted=$(on_pi "$ip" "readlink /run/booted-system")
  kernel=$(on_pi "$ip" "readlink -f /run/booted-system/kernel")
  new_kernel=$(on_pi "$ip" "readlink -f $path/kernel")
  if [ "$current" != "$path" ] || [ "$booted" != "$path" ] || [ "$kernel" != "$new_kernel" ]; then
    echo "  not running the new system: current $current, booted $booted, kernel $kernel"
    return 1
  fi
  healthy "$host" || return 1
  retry 10 answers "$peer" "$ip" || { echo "  no answer on $ip, asked from $peer"; return 1; }
}

# Back to the previous generation. Reboots into it when its kernel differs from
# the running one, otherwise switches live. The Pi stays drained.
rollback_dns_pi() {
  local host=$1 ip=${IP[$1]}
  echo "  rolling $host back to its previous generation"
  on_pi "$ip" "sudo nix-env -p $PROFILE --rollback" || return 1
  if [ "$(on_pi "$ip" "readlink -f $PROFILE/kernel")" != "$(on_pi "$ip" "readlink -f /run/booted-system/kernel")" ]; then
    on_pi "$ip" "sudo $PROFILE/bin/switch-to-configuration boot" || return 1
    reboot_and_wait "$host" || return 1
  else
    on_pi "$ip" "sudo $PROFILE/bin/switch-to-configuration switch" || return 1
  fi
  healthy "$host"
}

fail() {
  echo "::error::$1"
  exit 1
}

# Health check and undrain, then the Pi must hold its floating address again
# and answer on it, asked from the peer.
undrain_and_check() {
  local host=$1 peer=${PEER[$1]}
  echo "  undraining"
  undrain "$host"
  if retry 30 holds "$host" "${VIP[$host]}" && retry 10 answers "$peer" "${VIP[$host]}"; then
    echo "  holds ${VIP[$host]} again"
    return 0
  fi
  echo "  did not take ${VIP[$host]} back, or doesn't answer on it"
  drain "$host" || true
  return 1
}

deploy_dns_pi() {
  local host=$1 path=$2 ip=${IP[$1]} peer=${PEER[$1]}

  on_pi "$ip" true || fail "Can't reach $host. Nothing was deployed to it; later hosts were not deployed."
  if [ "$(on_pi "$ip" 'readlink /run/current-system')" = "$path" ]; then
    if ! drained "$host"; then
      echo "  already running $path"
      return 0
    fi
    echo "  already running $path, but drained: checking it"
    dns_pi_healthy "$host" "$path" ||
      fail "$host is on the new system but unhealthy; it stays drained. Later hosts were not deployed."
    undrain_and_check "$host" ||
      fail "$host is healthy but didn't take back ${VIP[$host]}; it stays drained. Later hosts were not deployed."
    return 0
  fi

  # The first rollout of keepalived: the peer doesn't run it yet, so there is
  # nothing to hand over to. Nothing points at the floating addresses yet
  # either, and clients still have the peer's own address.
  local handover=1
  if ! has_keepalived "$peer"; then
    echo "  $peer doesn't run keepalived yet (first rollout): no handover"
    handover=0
  fi

  if [ $handover = 1 ]; then
    echo "  checking $peer before draining"
    if drained "$peer"; then
      fail "$peer is drained, so $host can't be. Fix and undrain $peer first. Nothing was deployed to $host."
    fi
    healthy "$peer" || fail "$peer is unhealthy, so $host can't be drained. Nothing was deployed to $host."
  fi

  echo "  draining"
  drain "$host"
  if [ $handover = 1 ]; then
    if ! retry 20 holds "$peer" "${VIP[$host]}" || ! holds "$peer" "${VIP[$peer]}" ||
       ! retry 10 answers "$host" "${VIP[$host]}" || ! answers "$host" "${VIP[$peer]}"; then
      undrain "$host"
      fail "$peer didn't take both floating addresses, or they don't answer. $host was undrained; nothing was deployed to it."
    fi
    echo "  $peer holds ${VIP[$host]} and ${VIP[$peer]}, and both answer"
  fi

  echo "  copying closure"
  if ! nix copy --no-check-sigs --substitute-on-destination \
      ${SYSTEMS_STORE:+--from "$SYSTEMS_STORE"} --to "ssh-ng://tom@$ip" "$path"; then
    undrain "$host" || true
    fail "Copying the system to $host failed. It was undrained; nothing changed on it. Later hosts were not deployed."
  fi

  echo "  making it the boot default"
  if ! on_pi "$ip" "sudo nix-env -p $PROFILE --set '$path' && sudo '$path/bin/switch-to-configuration' boot"; then
    rollback_dns_pi "$host" || true
    fail "$host failed to install the new system and was rolled back. It stays drained; later hosts were not deployed."
  fi

  if reboot_and_wait "$host" && dns_pi_healthy "$host" "$path" && undrain_and_check "$host"; then
    echo "  healthy"
    return 0
  fi

  if ! drained "$host" 2>/dev/null; then drain "$host" || true; fi
  if rollback_dns_pi "$host"; then
    fail "$host failed its checks on the new system and was rolled back. It stays drained, so $peer holds both floating addresses: undrain it by hand. Later hosts were not deployed."
  fi
  fail "$host failed its checks on the new system, and the rollback failed too. It stays drained, so $peer holds both floating addresses. Later hosts were not deployed."
}

deploy_live() {
  local host=$1 path=$2 ip=${IP[$1]}

  if [ "$(on_pi "$ip" 'readlink /run/current-system')" = "$path" ]; then
    echo "  already running $path"
    return 0
  fi

  echo "  copying closure"
  nix copy --no-check-sigs --substitute-on-destination \
    ${SYSTEMS_STORE:+--from "$SYSTEMS_STORE"} --to "ssh-ng://tom@$ip" "$path"

  echo "  switching"
  if on_pi "$ip" "sudo nix-env -p $PROFILE --set '$path' && sudo '$path/bin/switch-to-configuration' switch" &&
     healthy "$host"; then
    echo "  healthy"
  else
    echo "  rolling $host back"
    on_pi "$ip" "sudo nix-env -p $PROFILE --rollback && sudo $PROFILE/bin/switch-to-configuration switch"
    fail "$host failed to switch or failed its health check, and was rolled back. Later hosts were not deployed."
  fi
}

# A DNS Pi that an earlier run left drained goes first: its peer can't be
# drained while it is.
first=() rest=()
for arg in "$@"; do
  host=${arg%%=*}
  if [ -n "${PEER[$host]:-}" ] && drained "$host" 2>/dev/null; then
    first+=("$arg")
  else
    rest+=("$arg")
  fi
done

for arg in "${first[@]}" "${rest[@]}"; do
  host=${arg%%=*} path=${arg#*=}
  echo "▸ $host (${IP[$host]})"
  if [ -n "${PEER[$host]:-}" ]; then
    deploy_dns_pi "$host" "$path"
  else
    deploy_live "$host" "$path"
  fi
done
