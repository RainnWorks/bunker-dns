{ pkgs, ... }:

{
  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    host = "0.0.0.0";
    port = 3000;
    extraArgs = [ "--no-check-update" ];
    settings = {
      dns = {
        bind_hosts = [ "127.0.0.1" ];
        port = 5353;
        upstream_dns = [ "127.0.0.1:5335" ];
        bootstrap_dns = [];
        fallback_dns = [];
        ratelimit = 0;
        fastest_addr = false;
        cache_size = 8388608;
        cache_ttl_min = 0;
        cache_ttl_max = 0;
        use_private_ptr_resolvers = false;
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        parental_enabled = false;
        safebrowsing_enabled = false;
        safesearch_enabled = false;
        # Return NXDOMAIN for blocked domains instead of the default 0.0.0.0.
        # A 0.0.0.0 answer makes clients try to connect to 0.0.0.0 and hang;
        # NXDOMAIN ("not found") lets them fail cleanly and move on.
        # NB: in AdGuard Home (schema 29) this key lives under `filtering`,
        # not `dns` — putting it under `dns` is silently dropped on load.
        blocking_mode = "nxdomain";
      };
      querylog = {
        enabled = true;
        file_enabled = false;
        interval = "24h";
        size_memory = 256;
      };
      statistics = {
        enabled = false;
        interval = "24h";
      };
      filters = [
        { enabled = true; url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"; name = "AdGuard DNS filter"; id = 1; }
        { enabled = true; url = "https://small.oisd.nl/domainswild2"; name = "OISD Blocklist"; id = 1604764603; }
        { enabled = true; url = "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt"; name = "Smart TV"; id = 1604764606; }
        { enabled = true; url = "https://easylist-downloads.adblockplus.org/fanboy-annoyance.txt"; name = "Annoyances"; id = 1604764608; }
      ];
      user_rules = [
        "@@||device-api.urbanairship.com^$important"
        "@@||fonts.gstatic.com^$important"
        "@@||www.passportjs.org^$important"
        "@@||app.datadoghq.com^$important"
        "@@||static.datadoghq.com^$important"
        "@@||samsung.com^$important"
        "@@||concierge.analytics.console.aws.a2z.com^$important"
        "@@||ichnaea.netflix.com^$important"
        "@@||nrdp.prod.ftl.netflix.com^$important"
        "@@||push.prod.netflix.com^$important"
        "@@||code.visualstudio.com^$important"
        "@@||www.husqvarna.com^$important"
        "@@||oss.oetiker.ch^$important"
        "@@||app.gitbook.com^$important"
        "@@||d3e54v103j8qbb.cloudfront.net^$important"
        "@@||cdn.samsungcloudsolution.com^$important"
        "@@||lcprd1.samsungcloudsolution.net^$important"
        "@@||ypu.samsungelectronics.com^$important"
        "@@||i7x7p5b7.stackpathcdn.com^$important"
        "@@||docs.datadoghq.com^$important"
        "@@||www.dynamodbbook.com^$important"
        "@@||check2.tsb.co.uk^$important"
        "@@||i.instagram.com^$important"
        "@@||api-glb-euw3b.smoot.apple.com^$important"
        "@@||tr.iadsdk.apple.com^$important"
        "@@||amp-api-edge.apps.apple.com^$important"
        "@@||cdn.tagcommander.com^$important"
        "@@||www.fdj.fr^$important"
        "@@||www.tobiipro.com^$important"
        "@@||via.placeholder.com^$important"
        "@@||ios.prod.http1.netflix.com^$important"
        "@@||www.gumtree.com^$important"
        "@@||url3148.rowm.co^$important"
        "@@||api2.amplitude.com^$important"
        "@@||downloads.sentry-cdn.com^$important"
        "@@||secure.dhgate.com^$important"
        "||info.cspserver.net^$important"
        "@@||codeium.com^"
        "@@||windsurf.com^"
        "@@||codeiumdata.com^"
        # Bambu Lab printer cloud event/telemetry endpoint. A blocklist
        # (OISD/AdGuard) flags it as tracking, but the printer's cloud-connect
        # handshake reports device events here; a 0.0.0.0 block answer stalls
        # the connection and the printer drops offline. Allowlist so it resolves.
        "@@||event.bblmw.com^$important"
      ];
      dhcp.enabled = false;
    };
  };

  systemd.services.adguardhome = {
    after = [ "unbound.service" ];
    wants = [ "unbound.service" ];
  };

  systemd.services.adguardhome.serviceConfig = {
    MemoryMax = "128M";
  };

  # AdGuard tries to download filter lists on startup, but DNS isn't ready yet.
  # This service waits for DNS to work, then triggers a filter refresh.
  systemd.services.adguardhome-refresh-filters = {
    description = "Refresh AdGuard Home filter lists";
    after = [ "adguardhome.service" "network-online.target" ];
    wants = [ "adguardhome.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ curl ];
    script = ''
      # Wait until Unbound can resolve external domains
      for i in $(seq 1 30); do
        if curl -sf http://127.0.0.1:3000/control/filtering/status > /dev/null 2>&1; then
          break
        fi
        sleep 2
      done
      sleep 5
      curl -sf -X POST http://127.0.0.1:3000/control/filtering/refresh \
        -d '{"whitelist":false}' \
        -H 'Content-Type: application/json' || true
    '';
  };

  # AdGuard's working dir intentionally persists on the SD card (no tmpfs).
  # The high-churn writers — query log and statistics — are already disabled
  # above, so on-disk writes are just the ~daily filter-list refresh and the
  # occasional config rewrite: negligible wear. Persisting matters because the
  # filter lists then survive reboots; a RAM-backed dir would force a full
  # re-download on every boot, opening a fail-open window and breaking blocking
  # whenever a list's source is unreachable (e.g. OISD's IPv4 timing out).
}
