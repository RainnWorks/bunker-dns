{ lib, modulesPath, ... }:

# Internal helper. Shared boot scaffolding for Raspberry Pi hosts. Imported
# by the per-board public modules (pi-zero2w.nix, pi4.nix); not meant to be
# imported by hosts directly. Pulls in modules/base.nix transitively so a
# host that imports a hardware/<board>.nix automatically gets the universal
# host setup (SSH, NTP, users, etc.) without an explicit base.nix import.

{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    ../../base.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # The rpi vendor kernels list initrd modules that don't exist in mainline
  # nixpkgs (no harm in skipping them).
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x: super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.swraid.enable = lib.mkForce false;

  hardware.enableRedistributableFirmware = lib.mkForce false;
}
