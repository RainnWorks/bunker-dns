{ pkgs, lib, ... }:

{
  imports = [ ./_shared/rpi-base.nix ];

  boot.kernelPackages = pkgs.linuxPackages_rpi02w;
  boot.initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" "r8152" ];
  boot.kernelModules = [ "r8152" ];

  # About 450 MB and no swap. Without swap, a burst of memory use (a deploy's
  # nix copy, a new release's first switch) thrashes instead of swapping:
  # dns2 stopped answering even SSH for hours on 2026-11-25. Compressed swap
  # in RAM (zstd, at most half the RAM) gives that headroom without writing
  # to the SD card.
  zramSwap.enable = true;

  hardware.deviceTree = {
    enable = true;
    filter = "*rpi-zero-2*";
  };

  sdImage.populateFirmwareCommands = lib.mkAfter ''
    chmod u+w firmware/config.txt
    cat >> firmware/config.txt <<EOT
    # Free up VRAM for system memory
    start_x=0
    gpu_mem=16
    # Enable USB host mode for Pi Zero 2 W (needed for USB ethernet HATs)
    dtoverlay=dwc2,dr_mode=host
    EOT
  '';
}
