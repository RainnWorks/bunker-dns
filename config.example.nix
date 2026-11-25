{
  # Your local domain (wildcard DNS will resolve *.domain to localIP)
  domain = "example.com";
  localIP = "192.168.1.100";

  # SSH public key for access
  sshKey = "ssh-ed25519 AAAA... your-key-here";

  # Timezone
  timeZone = "Europe/London";

  # The floating DNS address: the one DNS server your router hands out. The
  # primary node holds it; the other takes it over whenever the primary is
  # down. Pick it outside your router's DHCP pool. Leave `vip` out to hand out
  # the nodes' own addresses instead.
  vip = {
    address = "192.168.1.3";
    primary = "dns1";
  };
}
