{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.airplay-beacon;
  package = pkgs.callPackage ./package.nix { };
  args = [
    "--address"
    cfg.address
    "--serial"
    cfg.serial
    "--port"
    (toString cfg.port)
    "--adapter"
    cfg.adapter
    "--interval"
    "${toString cfg.healthInterval}s"
    "--retry"
    "15s"
    "--state-file"
    "/var/lib/airplay-beacon/address.json"
  ]
  ++ lib.optionals (cfg.mac != null) [
    "--mac"
    cfg.mac
  ]
  ++ lib.optionals (cfg.lanInterface != null) [
    "--interface"
    cfg.lanInterface
  ]
  ++ lib.optionals (cfg.discoveryNetworks != [ ]) [
    "--discovery-networks"
    (lib.concatStringsSep "," cfg.discoveryNetworks)
  ];
in
{
  options.services.airplay-beacon = {
    enable = lib.mkEnableOption "Bluetooth discovery of the paired Roku";
    package = lib.mkOption {
      type = lib.types.package;
      default = package;
    };
    address = lib.mkOption {
      type = lib.types.str;
      description = "Private IPv4 address hint for the Roku.";
    };
    serial = lib.mkOption {
      type = lib.types.str;
      description = "Paired Roku serial; checked before advertising any address.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 7000;
    };
    adapter = lib.mkOption {
      type = lib.types.str;
      default = "hci0";
    };
    healthInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
    };
    mac = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    lanInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    discoveryNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Optional private /24-or-smaller fallback scan ranges; at most 1024 addresses total, eight concurrent probes, once per five minutes while unavailable.";
    };
  };
  config = lib.mkIf cfg.enable {
    hardware.bluetooth.enable = true;
    hardware.bluetooth.powerOnBoot = true;
    systemd.services.airplay-beacon = {
      description = "Bluetooth discovery of the paired Roku AirPlay receiver";
      wantedBy = [
        "multi-user.target"
        "bluetooth.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "bluetooth.service" ];
      after = [
        "bluetooth.service"
        "network-online.target"
      ];
      partOf = [ "bluetooth.service" ];
      environment = {
        GOMAXPROCS = "1";
        GOMEMLIMIT = "16MiB";
      };
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArgs args}";
        DynamicUser = true;
        StateDirectory = "airplay-beacon";
        StateDirectoryMode = "0700";
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 10;
        MemoryHigh = "32M";
        MemoryMax = "64M";
        CPUQuota = "5%";
        TasksMax = 16;
        Nice = 10;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        CapabilityBoundingSet = "";
        LockPersonality = true;
        RestrictSUIDSGID = true;
      };
    };
  };
}
