# Two DNS nodes sharing the floating addresses, and a client asking them.
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
    vips = {
      dns1 = "192.168.1.3";
      dns2 = "192.168.1.4";
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
    A = "${cfg.vips.dns1}"
    B = "${cfg.vips.dns2}"
    LOCAL = "${cfg.localIP}"
    DRAIN = "/var/lib/keepalived/drained"

    def has(node, vip):
        return f"inet {vip}/" in node.succeed("ip -4 -o addr show dev eth1")

    def wait_holds(node, vip):
        node.wait_until_succeeds(f"ip -4 -o addr show dev eth1 | grep -q 'inet {vip}/'", timeout=90)

    def wait_lets_go(node, vip):
        node.wait_until_fails(f"ip -4 -o addr show dev eth1 | grep -q 'inet {vip}/'", timeout=90)

    def answers(addr):
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

    start_all()
    for n in [dns1, dns2]:
        n.wait_for_unit("coredns.service")
        n.wait_until_succeeds(
            "systemctl show -p LastTriggerUSecMonotonic keepalived-boot-delay.timer | grep -vq 'LastTriggerUSecMonotonic=0'"
        )
        n.wait_for_unit("keepalived.service")
    client.wait_for_unit("multi-user.target")

    with subtest("each node holds its own floating address"):
        wait_holds(dns1, A)
        wait_holds(dns2, B)
        assert not has(dns1, B) and not has(dns2, A)
        for addr in [A, B, "${own.dns1}", "${own.dns2}"]:
            answers(addr)

    with subtest("a drained node hands its address to the peer"):
        dns1.succeed(f"touch {DRAIN}")
        wait_holds(dns2, A)
        wait_lets_go(dns1, A)
        answers(A)
        answers("${own.dns1}")

    with subtest("a drained node stays drained through a reboot"):
        dns1.shutdown()
        answers(A)
        dns1.start()
        dns1.wait_for_unit("coredns.service")
        dns1.wait_for_unit("keepalived.service")
        dns1.sleep(20)
        assert not has(dns1, A) and not has(dns1, B)
        assert has(dns2, A) and has(dns2, B)

    with subtest("undrained, it takes its address back"):
        dns1.succeed(f"rm {DRAIN}")
        wait_holds(dns1, A)
        wait_lets_go(dns2, A)
        answers(A)

    with subtest("CoreDNS down: the peer takes the address"):
        dns2.succeed("systemctl stop coredns")
        wait_holds(dns1, B)
        answers(B)
        dns2.succeed("systemctl start coredns")
        wait_holds(dns2, B)
        wait_lets_go(dns1, B)

    with subtest("one node can't resolve the internet: the peer takes its address"):
        unbound_internet(dns2, False)
        wait_holds(dns1, B)
        answers(B)
        unbound_internet(dns2, True)
        wait_holds(dns2, B)
        wait_lets_go(dns1, B)

    with subtest("neither can resolve the internet: nothing moves, local names answer"):
        unbound_internet(dns1, False)
        unbound_internet(dns2, False)
        dns1.sleep(30)
        assert has(dns1, A) and not has(dns1, B)
        assert has(dns2, B) and not has(dns2, A)
        answers(A)
        answers(B)
        unbound_internet(dns1, True)
        unbound_internet(dns2, True)

    with subtest("a node loses power: the peer takes its address"):
        dns2.crash()
        wait_holds(dns1, B)
        answers(B)
  '';
}
