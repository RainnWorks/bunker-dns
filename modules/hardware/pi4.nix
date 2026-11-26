{ pkgs, nixos-hardware, ... }:

{
  imports = [ ./_shared/rpi-base.nix ];

  # The Raspberry Pi vendor kernel, from nixos-hardware: nixpkgs deprecated
  # linux-rpi in 26.05 and removed it for 26.11. The HiFiBerry needs the
  # vendor tree (its overlay, hifiberry-dacplus-std.dtbo, and its machine
  # driver, snd-soc-hifiberry-dacplus, aren't in mainline).
  #
  # Only the kernel: nixos-hardware's raspberry-pi-4 profile would also
  # take over the SD image's firmware partition (mkForce, without U-Boot
  # unless hardware.raspberry-pi.firmware.uboot.enable), which this repo's
  # images rely on.
  boot.kernelPackages = pkgs.linuxPackagesFor
    (pkgs.callPackage "${nixos-hardware}/raspberry-pi/common/kernel.nix" { rpiVersion = 4; });
  boot.initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];

  hardware.deviceTree = {
    enable = true;
    filter = "*rpi-4*";
  };
}
