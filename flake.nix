{
  description = "pi-dns-stack - Ad-blocking DNS on Raspberry Pi with NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    # Used selectively for packages we need newer than 25.05 ships
    # (e.g. spotifyd 0.4.2 needs rustc 1.88, only in unstable).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, ... }:
    let
      system = "aarch64-linux";
      pkgs-unstable = import nixpkgs-unstable { inherit system; };
      hosts = [ "dns1" "dns2" "kitchen-music" ];

      mkHost = cfg: host: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit cfg pkgs-unstable; };
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
    };
}
