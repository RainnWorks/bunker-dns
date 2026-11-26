{
  description = "pi-dns-stack - Ad-blocking DNS on Raspberry Pi with NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Used selectively for packages we want newer than stable ships
    # (spotifyd, see modules/audio/spotify-connect.nix).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Raspberry Pi vendor kernel for kitchen-music (modules/hardware/pi4.nix).
    # nixpkgs dropped linux-rpi after 26.05; nixos-hardware carries it now.
    # Only its kernel is used, built against our nixpkgs, so its own nixpkgs
    # input is never fetched. It has no binary cache: a bump that changes
    # the kernel means one ~90-minute build in CI (then the Actions cache).
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, ... }:
    let
      system = "aarch64-linux";
      pkgs-unstable = import nixpkgs-unstable { inherit system; };
      hosts = [ "dns1" "dns2" "kitchen-music" ];

      mkHost = cfg: host: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit cfg pkgs-unstable nixos-hardware; };
        modules = [ ./hosts/${host}.nix ];
      };

      # prefix + host -> nixosConfiguration, one per host, for one config.
      mkHosts = prefix: cfg: builtins.listToAttrs (map (host: {
        name = "${prefix}${host}";
        value = mkHost cfg host;
      }) hosts);
    in {
      # dns1, dns2, kitchen-music: built from your config.local.nix.
      # rainnworks-*: the same hosts with RainnWorks' own config
      # (sites/rainnworks.nix). That's what GitHub Actions builds and deploys.
      nixosConfigurations =
        mkHosts "" (import ./config.nix)
        // mkHosts "rainnworks-" (import ./sites/rainnworks.nix);

      # Two DNS nodes in VMs, failing over (tests/failover.nix). x86_64 so it
      # runs under KVM on an ordinary Linux machine or GitHub runner.
      checks.x86_64-linux.failover =
        nixpkgs.legacyPackages.x86_64-linux.testers.runNixOSTest ./tests/failover.nix;
    };
}
