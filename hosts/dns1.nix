{
  imports = [
    ../modules/hardware/pi-zero2w.nix
    ../modules/dns
    ../modules/dns/failover.nix
    ../modules/observability.nix
  ];

  networking.hostName = "dns1";

  # Static because dhcpcd drops its lease when the Samsung washer (IoT VLAN) falsely claims the DNS addresses.
  networking.useDHCP = false;
  networking.interfaces.enu1u4.ipv4.addresses = [
    { address = "192.168.96.45"; prefixLength = 23; }
  ];
  networking.defaultGateway = "192.168.96.1";

  # Shares the floating DNS addresses (cfg.vips) with the other DNS node.
  bunkerDns.failover = {
    interface = "enu1u4";
    peer = "192.168.96.60";
  };
}
