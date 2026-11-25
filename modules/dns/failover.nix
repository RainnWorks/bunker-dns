{ config, lib, pkgs, cfg, ... }:

# Floating DNS addresses, shared by two DNS nodes with keepalived (VRRP).
#
# cfg.vips names one floating address per node: the one that node holds while
# both are healthy. Your router hands out these addresses as DNS, not the
# nodes' own. Each node is the other's backup: when one is drained, fails its
# checks, or is off, the other holds both addresses, so clients never notice.
#
# The nodes talk unicast to each other (no multicast), on the wired interface.
# A node gives up its addresses when:
#
#   - it is drained: the file /var/lib/keepalived/drained exists. The deploy
#     creates it before a reboot and removes it once the node is healthy, so a
#     node that has just booted takes nothing back by itself. `sudo rm` it to
#     undrain by hand.
#   - CoreDNS on it stops answering a name under your domain.
#   - it can't resolve an internet name and its peer can. When both can't (the
#     internet is down), both lose the same priority and nothing moves: names
#     under your domain still answer on both addresses.
#
# CoreDNS listens on every address, so it answers on the floating addresses as
# well as the node's own; the own addresses keep working.

let
  inherit (lib) mkOption types;
  me = config.networking.hostName;
  failover = config.bunkerDns.failover;
  # This node's own address and prefix, from its static interface config.
  own = builtins.head config.networking.interfaces.${failover.interface}.ipv4.addresses;
  drainFile = "/var/lib/keepalived/drained";
  dig = "${pkgs.dig}/bin/dig";

  notDrained = pkgs.writeShellScript "vrrp-not-drained" ''
    [ ! -e ${drainFile} ]
  '';
  localNames = pkgs.writeShellScript "vrrp-local-names" ''
    [ "$(${dig} +short +time=2 +tries=1 @127.0.0.1 vrrp-check.${cfg.domain} A)" = "${cfg.localIP}" ]
  '';
  internetNames = pkgs.writeShellScript "vrrp-internet-names" ''
    ${dig} +short +time=2 +tries=1 @127.0.0.1 cloudflare.com A | ${pkgs.gnugrep}/bin/grep -q .
  '';

  # One VRRP instance per floating address. Router IDs follow the node names'
  # order (dns1 -> 51, dns2 -> 52), so both nodes agree on them.
  names = builtins.attrNames cfg.vips;
  instance = i: name: {
    name = "dns_${name}";
    value = {
      interface = failover.interface;
      virtualRouterId = 51 + i;
      # Its own address at 150, the peer's at 100. The internet check takes
      # 60 off, which puts a node below its peer only when the peer still
      # passes. The other two checks put the node in FAULT: it holds nothing.
      priority = if name == me then 150 else 100;
      unicastSrcIp = own.address;
      unicastPeers = [ failover.peer ];
      virtualIps = [{
        addr = "${cfg.vips.${name}}/${toString own.prefixLength}";
        dev = failover.interface;
      }];
      trackScripts = [ "not_drained" "local_names" "internet_names" ];
      extraConfig = ''
        # Drop VRRP packets from anything but the peer.
        check_unicast_src
        # Repeat the gratuitous ARP every minute while master, so the router
        # and switches keep the address on this node's MAC.
        garp_master_refresh 60
      '';
    };
  };
in
{
  options.bunkerDns.failover = {
    interface = mkOption {
      type = types.str;
      description = "The wired interface the floating addresses live on. Its first static IPv4 address is this node's own.";
    };
    peer = mkOption {
      type = types.str;
      description = "The other DNS node's own address.";
    };
  };

  # Without cfg.vips (an older config.local.nix), the nodes have no floating
  # addresses and answer on their own only, as before.
  config = lib.mkIf (cfg ? vips) {
    assertions = [{
      assertion = cfg.vips ? ${me};
      message = "cfg.vips has no floating address for ${me}.";
    }];

    services.keepalived = {
      enable = true;
      # VRRP and AH through the firewall.
      openFirewall = true;
      # Refuse to run a check that a non-root user could change. Ours are in
      # the Nix store, and run as keepalived_script.
      enableScriptSecurity = true;
      vrrpScripts = {
        # weight 0: failing puts the node in FAULT. init_fail: a script counts
        # as failing until it has passed `rise` times, so a node that has just
        # started takes nothing until it answers.
        not_drained = {
          script = "${notDrained}";
          interval = 2;
          timeout = 2;
          fall = 1;
          rise = 1;
          extraConfig = "init_fail";
        };
        local_names = {
          script = "${localNames}";
          interval = 3;
          timeout = 3;
          fall = 2;
          rise = 2;
          extraConfig = "init_fail";
        };
        internet_names = {
          script = "${internetNames}";
          interval = 5;
          timeout = 5;
          fall = 3;
          rise = 2;
          weight = -60;
          extraConfig = "init_fail";
        };
      };
      vrrpInstances = builtins.listToAttrs (lib.imap0 instance names);
    };

    # The checks run as this user, not root.
    users.users.keepalived_script = {
      isSystemUser = true;
      group = "keepalived_script";
    };
    users.groups.keepalived_script = { };

    # Where the drain file goes. On the SD card, so a drain survives a reboot.
    systemd.tmpfiles.rules = [ "d /var/lib/keepalived 0755 root root -" ];

    observability.monitoredServices = [ "keepalived" ];
  };
}
