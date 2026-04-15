self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.norish;
  inherit (lib)
    mkEnableOption mkOption mkIf mkDefault types literalExpression;

  # The norish package from this flake, or a user-overridden one.
  defaultPackage = self.packages.${pkgs.system}.default;
in
{
  options.services.norish = {
    enable = mkEnableOption "Norish recipe management server";

    package = mkOption {
      type = types.package;
      default = defaultPackage;
      defaultText = literalExpression "norish flake package";
      description = "The norish package to use.";
    };

    user = mkOption {
      type = types.str;
      default = "norish";
      description = "User account under which norish runs.";
    };

    group = mkOption {
      type = types.str;
      default = "norish";
      description = "Group under which norish runs.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/norish";
      description = "Directory for persistent data (uploads, etc.).";
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "TCP port to listen on.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address.";
    };

    authUrl = mkOption {
      type = types.str;
      description = ''
        Public URL at which the app is reachable (used by better-auth).
        Example: "https://norish.example.com"
      '';
    };

    databaseUrl = mkOption {
      type = types.str;
      default = "postgresql:///norish?host=/run/postgresql";
      description = "PostgreSQL connection URL.";
    };

    redisUrl = mkOption {
      type = types.str;
      default = "redis://127.0.0.1:6379";
      description = "Redis connection URL (used for job queues and real-time events).";
    };

    chromeWsEndpoint = mkOption {
      type = types.str;
      default = "ws://127.0.0.1:9222";
      description = "WebSocket endpoint for Chrome/Chromium (used for recipe scraping).";
    };

    masterKeyFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing a 32-byte base64 master key.
        Generate with: openssl rand -base64 32 > /run/keys/norish-master-key
      '';
    };

    passwordAuthEnabled = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = ''
        Whether to allow email/password login. When set, this value is synced
        to the database on every startup, overriding any admin UI setting.
        When null (default), the database value is left untouched.
      '';
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional environment variables passed to the service.";
      example = literalExpression ''
        {
          OPENAI_API_KEY = "sk-…";
          DEFAULT_LOCALE = "en";
        }
      '';
    };

    extraEnvFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file containing additional environment variables in KEY=VALUE
        format (loaded via systemd EnvironmentFile, so secrets stay off the
        Nix store).
      '';
    };

    extraSecretEnv = mkOption {
      type = types.attrsOf types.path;
      default = { };
      description = ''
        Map of environment variable name to secret file path. Each file is
        loaded via systemd LoadCredential (raw value, no KEY= prefix needed)
        and exported to the process environment. Use for secrets like
        OIDC_CLIENT_SECRET that must stay off the Nix store.
      '';
      example = literalExpression ''
        { OIDC_CLIENT_SECRET = config.age.secrets.norish-oidc-secret.path; }
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the firewall for the norish port.";
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = true;
      description = "Norish service user";
    };

    users.groups.${cfg.group} = { };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.norish = {
      description = "Norish recipe management server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "postgresql.service" "redis.service" ];

      environment = {
        NODE_ENV = "production";
        PORT = toString cfg.port;
        HOST = cfg.host;
        AUTH_URL = cfg.authUrl;
        DATABASE_URL = cfg.databaseUrl;
        REDIS_URL = cfg.redisUrl;
        CHROME_WS_ENDPOINT = cfg.chromeWsEndpoint;
        UPLOADS_DIR = "${cfg.stateDir}/uploads";
        NEXT_TELEMETRY_DISABLED = "1";
        SKIP_ENV_VALIDATION = "0";
        # yt-dlp binary from nixpkgs
        YTDLP_PATH = "${pkgs.yt-dlp}/bin/yt-dlp";
      } // lib.optionalAttrs (cfg.passwordAuthEnabled != null) {
        PASSWORD_AUTH_ENABLED = if cfg.passwordAuthEnabled then "true" else "false";
      } // cfg.extraEnv;

      # Prepend runtime tools to PATH (avoids conflicting with systemd's default PATH)
      path = [ pkgs.ffmpeg pkgs.nodejs_22 pkgs.coreutils ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "${cfg.package}/lib/norish";

        # Load optional extra secrets from file
        EnvironmentFile = lib.optional (cfg.extraEnvFile != null) cfg.extraEnvFile;

        # Load the raw master key and any extra secrets via credentials.
        # Files may contain bare values (no KEY= prefix needed).
        LoadCredential = [ "norish-master-key:${cfg.masterKeyFile}" ]
          ++ lib.mapAttrsToList
               (name: path: "${lib.toLower (lib.replaceStrings ["_"] ["-"] name)}:${path}")
               cfg.extraSecretEnv;

        # State & uploads live outside the Nix store
        StateDirectory = "norish";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "norish";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.stateDir ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        SystemCallFilter = [ "@system-service" ];
        SystemCallErrorNumber = "EPERM";
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
      };

      script = ''
        export MASTER_KEY="$(< "$CREDENTIALS_DIRECTORY/norish-master-key")"
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
          export ${name}="$(< "$CREDENTIALS_DIRECTORY/${lib.toLower (lib.replaceStrings ["_"] ["-"] name)}")"
        '') cfg.extraSecretEnv)}
        exec ${cfg.package}/bin/norish
      '';

      preStart = ''
        mkdir -p ${cfg.stateDir}/uploads
        chmod 0750 ${cfg.stateDir}/uploads
      '';
    };
  };
}
