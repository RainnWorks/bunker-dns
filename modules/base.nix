{ pkgs, lib, cfg, ... }:

{
  time.timeZone = cfg.timeZone;

  services.timesyncd.enable = true;
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  # Use NTP by IP to avoid chicken-and-egg with DNS (Pi has no RTC).
  networking.timeServers = [
    "162.159.200.1"   # time.cloudflare.com (anycast, nearby)
    "131.188.3.222"   # ntp1.fau.de (Germany)
    "131.188.3.223"   # ntp2.fau.de (Germany)
    "193.190.253.212" # ntp.belnet.be (Belgium)
  ];

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      # Default 10:30:100 + 2-minute LoginGraceTime makes sshd refuse new
      # connections during a burst (e.g. nix-copy + parallel ssh sessions
      # during a deploy). Higher startup cap and shorter grace clears the
      # queue faster.
      MaxStartups = "30:30:100";
      LoginGraceTime = "30s";
    };
  };

  users.users.tom = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ cfg.sshKey ] ++ (cfg.deployKeys or [ ]);
  };

  security.sudo.wheelNeedsPassword = false;

  # Let wheel users push closures via `nix copy --to ssh-ng://...` for remote
  # deploys (`nixos-rebuild --target-host`). Without this, only root can write
  # to the store, and untrusted users can't push unsigned paths even with
  # --no-check-sigs.
  nix.settings.trusted-users = [ "root" "@wheel" ];

  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=32M
    SystemMaxUse=0
  '';

  fileSystems."/var/log" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=0755" "size=32m" ];
  };

  environment.systemPackages = with pkgs; [
    vim
    curl
    jq
    dig
  ];

  system.stateVersion = "25.05";
}
