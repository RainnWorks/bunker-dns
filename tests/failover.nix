# Two DNS nodes sharing the floating address, and a client asking it.
#
#   nix build .#checks.x86_64-linux.failover -L
#
# Runs the real DNS stack (modules/dns) and modules/dns/failover.nix in VMs,
# with the test VLAN's eth1 standing in for the Pis' enu1u4. There is no
# internet in the VMs, so Unbound answers cloudflare.com from local data,
# which the test removes to fake a node that can't resolve the internet.
{ pkgs, ... }:

let
  cfg = {
    domain = "example.com";
    localIP = "192.168.1.100";
    vip = {
      address = "192.168.1.3";
      primary = "dns1";
    };
  };
  own = {
    dns1 = "192.168.1.45";
    dns2 = "192.168.1.60";
  };

  dnsNode = me: peer: { lib, ... }: {
    imports = [
      ../modules/dns
      ../modules/dns/failover.nix
      ../modules/observability.nix
    ];
    _module.args.cfg = cfg;
    virtualisation.vlans = [ 1 ];
    virtualisation.memorySize = 1024;
    # No internet, even where the build has network: the test decides what
    # "the internet" answers.
    virtualisation.restrictNetwork = true;
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      { address = own.${me}; prefixLength = 24; }
    ];
    bunkerDns.failover = {
      interface = "eth1";
      peer = own.${peer};
    };
    services.unbound.settings.server.local-data = [ ''"cloudflare.com. A 104.16.132.229"'' ];
  };
in
{
  name = "bunker-dns-failover";

  nodes = {
    dns1 = dnsNode "dns1" "dns2";
    dns2 = dnsNode "dns2" "dns1";
    client = { lib, ... }: {
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        { address = "192.168.1.10"; prefixLength = 24; }
      ];
      environment.systemPackages = [ pkgs.dig ];
    };
  };

  testScript = ''
    VIP = "${cfg.vip.address}"
    LOCAL = "${cfg.localIP}"
    DRAIN = "/var/lib/keepalived/drained"

    def has(node):
        return f"inet {VIP}/" in node.succeed("ip -4 -o addr show dev eth1")

    def wait_holds(node):
        node.wait_until_succeeds(f"ip -4 -o addr show dev eth1 | grep -q 'inet {VIP}/'", timeout=90)

    def wait_lets_go(node):
        node.wait_until_fails(f"ip -4 -o addr show dev eth1 | grep -q 'inet {VIP}/'", timeout=90)

    def answers(addr=VIP):
        # dig ignores a reply from any other address than the one it asked,
        # so this also checks the answer comes back from the floating address.
        client.wait_until_succeeds(
            f"[ \"$(dig +short +time=1 +tries=1 @{addr} anything.${cfg.domain})\" = {LOCAL} ]",
            timeout=60,
        )

    def unbound_internet(node, up):
        if up:
            node.succeed("unbound-control local_data 'cloudflare.com. A 104.16.132.229'")
        else:
            node.succeed("unbound-control local_data_remove cloudflare.com")
        # AdGuard and CoreDNS cache in front of Unbound.
        node.succeed("systemctl restart adguardhome coredns")

    def stays(holder, other, secs=20):
        holder.sleep(secs)
        assert has(holder) and not has(other)

    start_all()
    for n in [dns1, dns2]:
        n.wait_for_unit("coredns.service")
        n.wait_until_succeeds(
            "systemctl show -p LastTriggerUSecMonotonic keepalived-boot-delay.timer | grep -vq 'LastTriggerUSecMonotonic=0'"
        )
        n.wait_for_unit("keepalived.service")
    client.wait_for_unit("multi-user.target")

    with subtest("dns1 holds the floating address"):
        wait_holds(dns1)
        stays(dns1, dns2, 10)
        for addr in [VIP, "${own.dns1}", "${own.dns2}"]:
            answers(addr)

    with subtest("draining the backup moves nothing"):
        dns2.succeed(f"touch {DRAIN}")
        stays(dns1, dns2)
        answers()
        dns2.succeed(f"rm {DRAIN}")

    with subtest("draining dns1 hands the address to dns2"):
        dns1.succeed(f"touch {DRAIN}")
        wait_holds(dns2)
        wait_lets_go(dns1)
        answers()
        answers("${own.dns1}")

    with subtest("a drained dns1 stays drained through a reboot"):
        dns1.shutdown()
        answers()
        dns1.start()
        dns1.wait_for_unit("coredns.service")
        dns1.wait_for_unit("keepalived.service")
        stays(dns2, dns1)

    with subtest("undrained, dns1 takes the address back"):
        dns1.succeed(f"rm {DRAIN}")
        wait_holds(dns1)
        wait_lets_go(dns2)
        answers()

    with subtest("CoreDNS down on dns1: dns2 takes the address"):
        dns1.succeed("systemctl stop coredns")
        wait_holds(dns2)
        answers()
        dns1.succeed("systemctl start coredns")
        wait_holds(dns1)
        wait_lets_go(dns2)

    with subtest("dns1 can't resolve the internet, dns2 can: dns2 takes the address"):
        unbound_internet(dns1, False)
        wait_holds(dns2)
        answers()
        unbound_internet(dns1, True)
        wait_holds(dns1)
        wait_lets_go(dns2)

    with subtest("only the backup can't resolve the internet: nothing moves"):
        unbound_internet(dns2, False)
        stays(dns1, dns2, 30)
        unbound_internet(dns2, True)

    with subtest("neither can resolve the internet: nothing moves, local names answer"):
        unbound_internet(dns1, False)
        unbound_internet(dns2, False)
        stays(dns1, dns2, 30)
        answers()
        unbound_internet(dns1, True)
        unbound_internet(dns2, True)

    with subtest("dns1 loses power: dns2 takes the address"):
        wait_holds(dns1)
        dns1.crash()
        wait_holds(dns2)
        answers()
  '';
}
