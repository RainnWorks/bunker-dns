{ pkgs, lib, ... }:

{
  imports = [ ./_shared/rpi-base.nix ];

  # The generic aarch64 kernel, the one NixOS's own aarch64 SD image boots
  # on a Pi 3 or Zero 2 W, and on cache.nixos.org. nixpkgs 26.05's linux-rpi
  # isn't: Hydra stopped building it, and nixpkgs drops it after 26.05.
  # Nothing here needs the vendor kernel. U-Boot already loads the upstream
  # device tree (bcm2837-rpi-zero-2-w.dtb), and the SD card (sdhost), USB
  # (dwc2), the firmware interface and the watchdog (bcm2835-wdt, which is
  # also how the Pi reboots) are built in. r8152 is a module, loaded below.
  boot.kernelPackages = pkgs.linuxPackages;
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
    # The upstream device tree leaves the USB controller in OTG mode, which
    # picks host or device from the ID pin. Force host, for the USB ethernet
    # HAT. The dtoverlay line in config.txt below doesn't reach Linux: it
    # changes the firmware's device tree, and U-Boot boots Linux with this one.
    overlays = [
      {
        name = "dwc2-host";
        dtsText = ''
          /dts-v1/;
          /plugin/;
          / {
            compatible = "brcm,bcm2837";
            fragment@0 {
              target-path = "/soc/usb@7e980000";
              __overlay__ { dr_mode = "host"; };
            };
          };
        '';
      }
    ];
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
