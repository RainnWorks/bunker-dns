{ config, pkgs, lib, ... }:

let
  rpiKernel = config.boot.kernelPackages.kernel;

  # NixOS's hardware.deviceTree.overlays uses an apply_overlays.py that skips
  # overlays whose `compatible` string doesn't intersect the base DTB's. The
  # hifiberry overlay declares `brcm,bcm2835` (the rpi convention for "any
  # rpi SoC"), but the Pi 4 DTB is `brcm,bcm2711`, so the check incorrectly
  # rejects it. Bypass the check by pre-merging the DTB ourselves and feeding
  # it via dtbSource.
  #
  # Note: hifiberry-dacplus-std covers the DAC+ Standard, Amp2, and Amp4
  # family (kernel >= 6.1.77). For the Amp4 Pro use hifiberry-amp4pro instead.
  mergedDtbs = pkgs.runCommandNoCC "rpi-dtbs-with-hifiberry-amp4" {
    nativeBuildInputs = [ pkgs.dtc ];
  } ''
    mkdir -p $out
    cp -r ${rpiKernel}/dtbs/* $out/
    chmod -R u+w $out
    fdtoverlay \
      -i $out/broadcom/bcm2711-rpi-4-b.dtb \
      -o $out/broadcom/bcm2711-rpi-4-b.dtb.merged \
      ${rpiKernel}/dtbs/overlays/hifiberry-dacplus-std.dtbo
    mv $out/broadcom/bcm2711-rpi-4-b.dtb.merged $out/broadcom/bcm2711-rpi-4-b.dtb
  '';
in
{
  hardware.deviceTree.dtbSource = mergedDtbs;

  # NixOS's modules-shrunk derivation strips kernel modules that aren't
  # explicitly referenced. Listing the HiFiBerry stack here ensures the
  # BCM I2S driver, the dacplus machine driver, and the PCM512x codec
  # driver survive into the deployed kernel-modules tree.
  boot.kernelModules = [
    "snd_soc_bcm2835_i2s"
    "snd_soc_hifiberry_dacplus"
    "snd_soc_pcm512x_i2c"
  ];

  # Default ALSA to the HiFiBerry by card name (stable across boots — numeric
  # card IDs depend on probe order, with onboard audio at card0 and USB audio
  # at card2). The `softvol` layer in front of the hardware bounds the dB
  # range so apps see a slider that's actually usable across its full travel:
  #
  #   slider 0%  → -45 dB (very quiet but audible)
  #   slider 50% → softvol log-mapped (rough background-music level)
  #   slider 100% → 0 dB (full output — as loud as the amp will go)
  #
  # The PCM5121's Digital control alone has the *full* hardware range
  # (-103.5 dB to 0 dB), which on this amp+speaker combo gives a slider where
  # most of the useful range is squashed into a few percentage points at one
  # end — either way you cut it (linear or log curve). HiFiBerryOS uses this
  # same softvol pattern; we replicate it. Tweak min_dB / max_dB if your
  # speakers + listening environment want a different window.
  environment.etc."asound.conf".text = ''
    pcm.!default {
        type plug
        slave.pcm "softvol_out"
    }

    pcm.softvol_out {
        type softvol
        slave.pcm "hw:CARD=sndrpihifiberry,0"
        control.name "SoftMaster"
        control.card sndrpihifiberry
        min_dB -45.0
        max_dB 0.0
        resolution 256
    }

    ctl.!default {
        type hw
        card sndrpihifiberry
    }
  '';

  # Let interactive logins (e.g. `aplay`, `speaker-test`) reach /dev/snd.
  users.users.tom.extraGroups = [ "audio" ];

  # For debugging the mixer over SSH (amixer/alsamixer/aplay).
  environment.systemPackages = [ pkgs.alsa-utils ];

  # The SoftMaster softvol control is a lazily-created ALSA user control: it
  # only exists once something has played through the softvol PCM, and then
  # persists until reboot. spotifyd looks it up on every volume change and,
  # early after boot, races the creation — its slider writes fail with
  # "No control with name 'SoftMaster'" and audio runs at full hardware
  # volume with a dead slider. Create the control before the players start
  # by pushing a moment of silence through the chain, then park it at a
  # safe level for whatever plays first.
  systemd.services.softvol-init = {
    description = "Instantiate SoftMaster softvol control before audio players start";
    wantedBy = [ "multi-user.target" ];
    after = [ "sound.target" "systemd-udev-settle.service" ];
    before = [ "spotifyd.service" "shairport-sync.service" ];
    path = [ pkgs.alsa-utils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # The card can appear a beat after sound.target on slow boots.
      for i in $(seq 1 10); do
        [ -e /proc/asound/sndrpihifiberry ] && break
        sleep 1
      done
      # Opening the default (plug -> softvol) PCM creates the control.
      aplay -D default -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/zero || true
      amixer -c sndrpihifiberry sset SoftMaster 40% || true
    '';
  };

  # Audio-stack settings specific to this HAT. Plain (non-mkDefault) values
  # override audio module mkDefault fallbacks; hosts can still override
  # these via lib.mkForce if needed.
  #
  # spotifyd writes to the SoftMaster control above (not the raw Digital
  # control), so its slider 0–100% maps linearly into the constrained
  # dB window. alsa_linear keeps the mapping predictable; softvol itself
  # supplies the log curve internally.
  services.spotifyd.settings.global = {
    volume_controller = "alsa_linear";
    mixer = "hw:CARD=sndrpihifiberry";
    control = "SoftMaster";
  };
}
