# RainnWorks' own config: dns1, dns2 and kitchen-music on Tower's LAN.
# Built as the rainnworks-* outputs of the flake, which GitHub Actions
# deploys. Nothing here is secret: the domain is public, and the same LAN
# address is in the public Inlustra/thenairn.com Caddyfile. Secrets go in
# secrets/*.sops.* instead.
let
  # The deploy key, accepted only from Tower, where the deploy job runs: its
  # runner is a container there, so the Pis see Tower's address.
  deployKey = ./../ci/deploy_ed25519.pub;
in
{
  domain = "thenairn.com";
  localIP = "192.168.96.14";
  sshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMgjqHkWgEeTFzrLvwaT7YyLiPqejAvXFYm1zsGpUIQf 1password";
  deployKeys =
    if builtins.pathExists deployKey
    then [ ''from="192.168.96.14" ${builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile deployKey)}'' ]
    else [ ];
  timeZone = "Europe/Paris";
  # The floating DNS addresses the UDM hands out (keepalived, see
  # modules/dns/failover.nix): each node's own while both are healthy. Outside
  # the LAN's DHCP pool (.96.11-.97.254). .96.2 is taken by the UDM itself;
  # .96.3 and .96.4 were free on 2026-11-25 (no reservation, ARP or ping).
  vips = {
    dns1 = "192.168.96.3";
    dns2 = "192.168.96.4";
  };
}
