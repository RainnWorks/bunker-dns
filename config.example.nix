{
  # Your local domain (wildcard DNS will resolve *.domain to localIP)
  domain = "example.com";
  localIP = "192.168.1.100";

  # SSH public key for access
  sshKey = "ssh-ed25519 AAAA... your-key-here";

  # Timezone
  timeZone = "Europe/London";

  # Floating DNS addresses: one per DNS node, the one it holds while both are
  # healthy. If a node goes down, the other holds both. Hand these out as DNS
  # from your router, and pick them outside its DHCP pool. Leave `vips` out to
  # run without them.
  vips = {
    dns1 = "192.168.1.3";
    dns2 = "192.168.1.4";
  };
}
