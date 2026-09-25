{
  description = "BunkerDNS - home DNS and ad blocking that keeps working when the internet does not, on Raspberry Pis with NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    # Used selectively for packages we need newer than 25.05 ships
    # (e.g. spotifyd 0.4.2 needs rustc 1.88, only in unstable).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, ... }:
    let
      system = "aarch64-linux";
      cfg = import ./config.nix;
      pkgs-unstable = import nixpkgs-unstable { inherit system; };
    in {
      nixosConfigurations.dns1 = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit cfg pkgs-unstable; };
        modules = [
          ./hosts/dns1.nix
        ];
      };

      nixosConfigurations.dns2 = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit cfg pkgs-unstable; };
        modules = [
          ./hosts/dns2.nix
        ];
      };

      nixosConfigurations.kitchen-music = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit cfg pkgs-unstable; };
        modules = [
          ./hosts/kitchen-music.nix
        ];
      };
    };
}
