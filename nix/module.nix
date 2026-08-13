{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.tileserver-gl;
  settingsFormat = pkgs.formats.json { };

  configFile =
    if cfg.configFile != null then
      # interpolation imports literal paths (e.g. ./config.json) into the
      # store; plain string paths ("/mnt/...") pass through unchanged
      "${cfg.configFile}"
    else if cfg.settings != null then
      settingsFormat.generate "tileserver-gl-config.json" cfg.settings
    else
      null;

  args =
    lib.optionals (configFile != null) [
      "--config"
      configFile
    ]
    ++ lib.optionals (cfg.file != null) [
      "--file"
      cfg.file
    ]
    ++ [
      "--port"
      (toString cfg.port)
    ]
    ++ lib.optionals (cfg.bind != null) [
      "--bind"
      cfg.bind
    ]
    ++ lib.optionals (cfg.publicUrl != null) [
      "--public_url"
      cfg.publicUrl
    ]
    ++ lib.optionals (cfg.verbose != null) [
      "--verbose"
      (toString cfg.verbose)
    ]
    ++ lib.optional cfg.silent "--silent"
    ++ lib.optional cfg.metrics "--metrics"
    ++ cfg.extraFlags;
in
{
  options.services.tileserver-gl = {
    enable = lib.mkEnableOption "tileserver-gl, a map tile server for JSON GL styles";

    package = lib.mkPackageOption pkgs "tileserver-gl" { };

    settings = lib.mkOption {
      type = lib.types.nullOr settingsFormat.type;
      default = null;
      example = lib.literalExpression ''
        {
          options.paths = {
            root = "/var/lib/tileserver-gl";
            fonts = "fonts";
            styles = "styles";
            mbtiles = "data";
          };
          styles.basic.style = "basic/style.json";
          data.openmaptiles.mbtiles = "tiles.mbtiles";
        }
      '';
      description = ''
        Contents of the tileserver-gl configuration file (config.json).
        See <https://tileserver.readthedocs.io/en/latest/config.html>.
        Mutually exclusive with {option}`services.tileserver-gl.configFile`.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an existing tileserver-gl config.json. Mutually exclusive
        with {option}`services.tileserver-gl.settings`.
      '';
    };

    file = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/tileserver-gl/tiles.mbtiles";
      description = ''
        A single MBTiles or PMTiles file (local path, http(s):// or s3://
        URL) to serve with an auto-generated configuration. Ignored if a
        configuration file is given.
      '';
    };

    bind = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1";
      description = "Address to bind to. Binds all interfaces if unset.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port to listen on.";
    };

    publicUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://tiles.example.org/";
      description = ''
        Public URL the server is exposed under (also used for host
        validation), passed as `--public_url`.
      '';
    };

    verbose = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 1 3);
      default = null;
      description = "Verbosity level (1-3).";
    };

    silent = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Less verbose output.";
    };

    metrics = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the Prometheus metrics endpoint.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--ignore-missing-files" ];
      description = "Extra command line flags passed to tileserver-gl.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tileserver-gl";
      description = ''
        Working directory of the server. Relative paths in the
        configuration (styles, fonts, mbtiles, ...) are resolved from
        here. Created automatically when left at the default; any other
        location must exist and be readable by the service.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the firewall for {option}`services.tileserver-gl.port`.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.settings == null || cfg.configFile == null;
        message = "services.tileserver-gl: settings and configFile are mutually exclusive.";
      }
    ];

    # Mesa (llvmpipe) so GL rendering works on headless machines
    hardware.graphics.enable = true;

    systemd.services.tileserver-gl = {
      description = "tileserver-gl map tile server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment.XDG_CACHE_HOME = "/var/cache/tileserver-gl";

      serviceConfig = {
        CacheDirectory = "tileserver-gl";
        # Raster tile rendering (maplibre-gl-native) needs a GLX-capable X
        # server; run headless under Xvfb like the upstream Docker image.
        ExecStart = "${lib.getExe pkgs.xvfb-run} -a ${lib.getExe cfg.package} ${lib.escapeShellArgs args}";
        WorkingDirectory = cfg.dataDir;
        StateDirectory = lib.mkIf (cfg.dataDir == "/var/lib/tileserver-gl") "tileserver-gl";
        DynamicUser = true;
        Restart = "on-failure";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallArchitectures = "native";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
