{ pkgs, lib, pkgs-unstable, ... }:

# Hardware-agnostic Spotify Connect endpoint via spotifyd. Volume defaults to
# software-mixed (`softvol`) so this works on any audio output. Hardware
# modules (e.g. modules/hardware/hifiberry-amp4.nix) can override
# `volume_controller`, `mixer`, and `control` via lib.mkDefault to enable
# hardware-mixer volume on capable DACs.

{
  # Pull spotifyd from nixos-unstable: 25.05 ships v0.4.1 which hits the
  # 2025 Spotify protocol change and 404s on every track. v0.4.2 (Nov 2025)
  # fixes it but requires rustc 1.88, only available in unstable.
  #
  # withMpris = false drops the dbus_mpris feature at compile time. The
  # default Linux build links MPRIS, which requires D-Bus — and on a
  # headless host with DynamicUser, neither the session bus (no $DISPLAY)
  # nor the system bus (RequestName silently times out under DynamicUser)
  # works without significant additional plumbing. We don't need media-
  # player metadata over D-Bus for "phone → speakers", so just drop it.
  # TODO: revisit if we ever want HA to control playback via MPRIS —
  # likely requires a static user instead of DynamicUser + a system-bus
  # policy file matching by user="spotifyd".
  nixpkgs.overlays = [
    (final: prev: {
      spotifyd = pkgs-unstable.spotifyd.override { withMpris = false; };
    })
  ];

  services.spotifyd = {
    enable = true;
    settings.global = {
      backend = "alsa";
      bitrate = 320;
      device_type = "speaker";
      # 32-bit output gives the volume_normalisation pregain extra headroom
      # before clipping; ALSA's `type plug` (in asound.conf set by hardware
      # modules) downconverts for DACs that can't accept S32 natively.
      audio_format = "S32";
      # Soft cap below the tmpfs hard cap (see fileSystems entry below) so
      # spotifyd evicts old entries instead of failing to write.
      max_cache_size = 268435456;  # 256 MB
      # Spotify's per-track loudness varies; normalise to a consistent
      # target to avoid one quiet track followed by an ear-blast.
      volume_normalisation = true;
      # First-connect default — spotifyd has no cached volume yet, so
      # without this it boots at 100%. Hosts can override per-room.
      initial_volume = 30;
      # Hardware-agnostic default: software volume control. Hardware modules
      # override to "alsa_linear" + their device's mixer/control if they
      # support hardware volume (sounds better, less CPU).
      volume_controller = lib.mkDefault "softvol";
      # device_name is set per-host (e.g. "Kitchen") so it shows up nicely
      # in Spotify's device picker rather than as the Linux hostname.
    };
  };

  # Cache lives in RAM, not on the SD card. spotifyd's NixOS module hard-
  # codes --cache-path /var/cache/spotifyd, so we mount tmpfs at that path.
  # Pi 4 (2GB) has plenty of headroom; cap at 512MB so a runaway can't OOM.
  # Cache survives until reboot, then re-fills lazily on next play.
  fileSystems."/var/cache/spotifyd" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=0755" "size=512m" ];
  };

  # Watchdog for a dead Spotify Connect websocket. spotifyd keeps a
  # websocket to Spotify's "dealer"; that is how phones see and control
  # the speaker. When it drops, spotifyd reconnects and logs
  # "active device is <...> with session <...>". After the DNS outage on
  # 2026-10-20 it failed twice and never logged that again: still running,
  # still logged in, still advertising "Kitchen", but no phone could use it
  # for a week. It doesn't exit, so Restart= never fires.
  #
  # The check reads the current run's journal: if the last websocket
  # failure is newer than the last reconnect and more than 3 minutes old,
  # restart. Healthy reconnects land within seconds, so 3 minutes leaves
  # room for a slow one.
  systemd.services.spotifyd-watchdog = {
    description = "Restart spotifyd when its Spotify Connect websocket has died";
    after = [ "spotifyd.service" ];
    serviceConfig.Type = "oneshot";
    path = with pkgs; [ systemd gnugrep gawk coreutils ];
    script = ''
      systemctl is-active --quiet spotifyd || exit 0
      run=$(systemctl show -p InvocationID --value spotifyd)
      [ -n "$run" ] || exit 0
      log=$(journalctl _SYSTEMD_INVOCATION_ID="$run" -o short-unix --no-pager)

      last() { printf '%s\n' "$log" | grep -aE "$1" | tail -n 1 | awk '{ print int($1) }'; }
      failed=$(last 'Websocket (connection failed|peer does not respond)')
      [ -n "$failed" ] || exit 0
      recovered=$(last 'active device is')
      if [ -n "$recovered" ] && [ "$recovered" -ge "$failed" ]; then exit 0; fi

      age=$(( $(date +%s) - failed ))
      if [ "$age" -gt 180 ]; then
        echo "websocket failed ''${age}s ago and never reconnected; restarting spotifyd"
        systemctl restart spotifyd
      fi
    '';
  };

  systemd.timers.spotifyd-watchdog = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "2min";
    };
  };

  # mDNS so <hostname>.local resolves on the LAN (Spotify Connect itself
  # advertises via Zeroconf independently).
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # Spotify Connect uses dynamic port ranges for the protocol — same problem
  # as Cast/AirPlay. Internal-only host, easier to drop the firewall.
  networking.firewall.enable = lib.mkForce false;
}
