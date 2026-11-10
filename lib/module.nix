{ lib, mkApp }:
{
  app,
  nixArgs,
  appBuilder,
}:
let
  pkgs = nixArgs.pkgs;
  inherit (nixArgs) lib;
  name = app.name;
  m = app.module or { };
  description = app.description or "";
  useNetwork = m.network or true;
  useStorage = m.storage or true;
  useUser = m.user or true;
  useGraphics = m.graphics or false;
  userService = m.userService or false;
  harden = m.harden or true;

  system = pkgs.stdenv.hostPlatform.system;
  output = mkApp {
    inherit
      appBuilder
      system
      pkgs
      app
      ;
  };

  cfg = nixArgs.config.services.${name};
  defaultEnable =
    if m ? defaultEnable then
      m.defaultEnable (nixArgs // { inherit cfg; })
    else
      true;
  appOptions = if m ? options then m.options (nixArgs // { inherit cfg; }) else { };

  service =
    args:
    if userService then
      { systemd.user.services.${name} = args; }
    else
      { systemd.services.${name} = args; };

  workingDirectory = if userService then "%S/${name}" else "/var/lib/${name}";

  isLeaf = option: option ? does;
  toNixOptions = builtins.mapAttrs (
    _: opt:
    if isLeaf opt then
      lib.mkOption (
        { default = null; }
        // opt.option
        // {
          type = lib.types.nullOr opt.option.type;
        }
      )
    else
      toNixOptions opt
  );
  toNixConfig =
    options: config:
    builtins.concatMap (
      optName:
      let
        opt = options.${optName};
        cfg = config.${optName};
      in
      if isLeaf opt then
        [
          (lib.mkIf (cfg != null) (
            opt.does {
              inherit service;
              value = cfg;
              config = args: { services.${name} = args; };
            }
          ))
        ]
      else
        toNixConfig opt cfg
    ) (builtins.attrNames options);
in
{
  options = {
    services.${name} = {
      enable = lib.mkEnableOption name // {
        default = defaultEnable;
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = output.package;
        description = ''
          ${name} equivalent executable.
        '';
      };

      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          cli args to pass to ${name} executable.
        '';
      };
    }
    // (toNixOptions appOptions);
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge (
      [
        (lib.mkIf useNetwork (service {
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
        }))
        (lib.mkIf useStorage (service {
          serviceConfig = {
            WorkingDirectory = workingDirectory;
            StateDirectory = name;
          };
        }))
        (lib.mkIf (useUser && !userService) (
          {
            users.groups.${name} = { };
            users.users.${name} =
              {
                isSystemUser = true;
                group = name;
              }
              // (lib.optionalAttrs useStorage {
                home = "/var/lib/${name}";
                createHome = true;
              });
          }
          // (service {
            serviceConfig = {
              User = name;
              Group = name;
            };
          })
        ))
        (lib.mkIf harden (service {
          serviceConfig = {
            NoNewPrivileges = lib.mkDefault true;
            ProtectSystem = lib.mkDefault "strict";
            # A user service keeps its state below the home directory, so
            # protecting the home directory would make `%S` inaccessible.
            ProtectHome = lib.mkDefault (!userService);
            PrivateTmp = lib.mkDefault true;
          };
        }))
        (lib.mkIf (output.cacheDirectory or false) (service {
          serviceConfig = {
            CacheDirectory = name;
          };
        }))
        (service {
          inherit description;
          wantedBy =
            if userService then
              (if useGraphics then [ "graphical-session.target" ] else [ "default.target" ])
            else
              (if useGraphics then [ "graphical.target" ] else [ "multi-user.target" ]);
          serviceConfig = {
            ExecStart = "${lib.getExe cfg.package} ${nixArgs.utils.escapeSystemdExecArgs cfg.args}";
            Restart = lib.mkDefault "on-failure";
          };
        })
      ]
      ++ (toNixConfig appOptions cfg)
    )
  );
}
