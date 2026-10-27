{
  description = "Application builders to run your app seamlessly on XnodeOS.";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    systems.url = "github:nix-systems/default";

    # Rust
    crate2nix = {
      url = "github:nix-community/crate2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";

    # Python
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      combine = list: builtins.foldl' (acc: elem: acc // elem) { } list;

      systems = import inputs.systems;
      eachSystem =
        pkgsImport: f:
        combine (
          builtins.map (
            system:
            f {
              inherit system;
              pkgs = import inputs.nixpkgs (
                {
                  inherit system;
                  config.allowUnfree = true;
                }
                // pkgsImport
              );
            }
          ) systems
        );

      # The same as `eachSystem`, but the result of every system is nested
      # under the name of the system.
      eachSystemBySystem =
        pkgsImport: f:
        lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import inputs.nixpkgs (
              {
                inherit system;
                config.allowUnfree = true;
              }
              // pkgsImport
            );
          }
        );

      lib = inputs.nixpkgs.lib;

      # ==================================================================
      # Override system
      # ==================================================================
      #
      # Every argument of every build step can be customized with
      #
      #   override.<scope>.<implementation>.<slot>
      #
      # `scope` is one of
      #
      #   check       the check (test) build
      #   package     the package build
      #   devshell    the development shell
      #   common      applies to all of the scopes above
      #
      # `implementation` is one of
      #
      #   crate2nix, naersk, crane, buildRustPackage,
      #   pyproject.nix, uv2nix, buildGoModule, buildNpmPackage
      #
      #   common      applies to all of the implementations above
      #
      # `slot` is either
      #
      #   * the name of a build step of the implementation
      #     (e.g. `buildPackage`, `buildDepsOnly`, `build`, `shell`, ...)
      #     in which case its value is an attribute set of arguments for
      #     that step, or
      #
      #   * a generic build argument (e.g. `buildInputs`, `nativeBuildInputs`,
      #     `env`, `meta`, ...) in which case its value is applied to the
      #     build of the implementation, wherever it fits best.
      #
      # The layers are applied from the least to the most specific one,
      # every layer overwrites the previous one:
      #
      #   1. the defaults of the implementation
      #   2. override.common.common
      #   3. override.common.<implementation>
      #   4. override.<scope>.common
      #   5. override.<scope>.<implementation>
      #
      # Attribute sets are merged recursively, every other value is
      # overwritten. Values of list arguments can be functions of their
      # previous value to extend them without losing the defaults:
      #
      #   buildInputs = prev: prev ++ [ pkgs.hello ];
      #
      # Generic arguments are additive: their lists are appended to the
      # lists of the build instead of replacing them. The arguments of a
      # build step replace the defaults of the step.
      #

      # Arguments that hold a list and can therefore be extended with a
      # function of their previous value.
      mergeableKeys = [
        "buildInputs"
        "buildInputs64"
        "checkInputs"
        "nativeBuildInputs"
        "nativeCheckInputs"
        "propagatedBuildInputs"
        "propagatedNativeBuildInputs"
        "testInputs"
        "patches"
        "makeFlags"
        "configureFlags"
        "buildFlags"
        "checkFlags"
        "installFlags"
      ];

      # Whether a value is a derivation. `lib.isDerivation` cannot be used
      # because it fails on values without a `type` attribute.
      isDerivation = value: builtins.isAttrs value && (value ? drvPath);

      # Merge `next` into `prev`. Attribute sets are merged recursively,
      # every other value of `next` overwrites the value of `prev`.
      # Functions of list arguments are applied to their previous value.
      # With `extendLists`, lists are concatenated instead of overwritten.
      mergeValues =
        {
          prev,
          next,
          extendLists ? false,
        }:
        let
          mergeKey =
            key:
            let
              previous = prev.${key};
              value = next.${key};
            in
            if builtins.isAttrs previous && builtins.isAttrs value then
              mergeValues {
                prev = previous;
                next = value;
                inherit extendLists;
              }
            else if builtins.isFunction value && (builtins.elem key mergeableKeys) then
              (if builtins.hasAttr key prev then value previous else value [ ])
            else if extendLists && builtins.isList previous && builtins.isList value then
              previous ++ value
            else
              value;
          shared = builtins.filter (key: builtins.hasAttr key prev && builtins.hasAttr key next) (
            builtins.attrNames next
          );
        in
        prev
        // next
        // builtins.listToAttrs (builtins.map (key: lib.nameValuePair key (mergeKey key)) shared);

      # Build steps of every implementation. `shell` (the development shell)
      # is available for every implementation.
      implementationSteps = {
        crate2nix = [ "build" ];
        naersk = [ "buildPackage" ];
        crane = [
          "buildPackage"
          "buildDepsOnly"
        ];
        buildRustPackage = [ "buildPackage" ];
        "pyproject.nix" = [ "buildPythonPackage" ];
        uv2nix = [
          "pythonSet"
          "venv"
          "application"
        ];
        buildGoModule = [ "buildGoModule" ];
        buildNpmPackage = [ "buildNpmPackage" ];
      };

      # Arguments of an implementation that are handled by the implementation
      # itself and can therefore not be applied generically.
      implementationSpecialArgs = {
        crate2nix = {
          features = "build";
          crateOverrides = "build";
          runTests = "build";
          testCrateFlags = "build";
          testInputs = "build";
          testPreRun = "build";
          testPostRun = "build";
        };
        naersk = { };
        crane = { };
        buildRustPackage = { };
        "pyproject.nix" = { };
        uv2nix = {
          override = "pythonSet";
        };
        buildGoModule = { };
        buildNpmPackage = { };
      };

      commonSteps = [ "shell" ];

      # The build steps that are available in a scope. The development shell
      # only has the `shell` step, the other scopes have the steps of the
      # implementation.
      scopeSteps =
        scope: implementation:
        if scope == "devshell" then commonSteps else implementationSteps.${implementation} or [ ];

      # Resolve the override tree of a scope for an implementation.
      #
      # Returns the arguments of every step of the scope (`stepArgs`) and the
      # generic arguments that have to be applied by the implementation
      # (`genericArgs`).
      resolveOverrides =
        {
          override,
          scope,
          implementation,
          defaults,
          specialArgs,
        }:
        let
          knownSteps = scopeSteps scope implementation;
          layers = [
            (override.common.common or { })
            (override.common.${implementation} or { })
            (override.${scope}.common or { })
            (override.${scope}.${implementation} or { })
          ];
          isStep = slot: builtins.elem slot knownSteps;
          isSpecial = slot: builtins.hasAttr slot specialArgs;
          fold =
            acc: layer:
            let
              stepSlots = lib.filterAttrs (slot: _: isStep slot) layer;
              specialSlots = lib.filterAttrs (slot: _: isSpecial slot) layer;
              genericSlots = lib.filterAttrs (slot: _: !(isStep slot) && !(isSpecial slot)) layer;
              mergeStep =
                step: previous:
                let
                  special = lib.filterAttrs (slot: target: target == step) specialSlots;
                in
                mergeValues {
                  prev = mergeValues {
                    prev = previous;
                    next = special;
                  };
                  next = stepSlots.${step} or { };
                };
              newSteps = lib.filterAttrs (step: _: !(builtins.hasAttr step acc.stepArgs)) stepSlots;
              stepArgs =
                lib.mapAttrs (step: previous: mergeStep step previous) acc.stepArgs
                // lib.mapAttrs (step: _: mergeStep step { }) newSteps;
            in
            {
              stepArgs = stepArgs;
              genericArgs = mergeValues {
                prev = acc.genericArgs;
                next = genericSlots;
                extendLists = true;
              };
            };
          initial = {
            stepArgs = defaults;
            genericArgs = { };
          };
        in
        builtins.foldl' fold initial layers;

      defaultModule =
        {
          app,
          nixArgs,
          builder,
        }:
        let
          pkgs = nixArgs.pkgs;
          lib = nixArgs.lib;
          name = app.name;
          description = app.description or "";
          useNetwork = if app.module or { } ? network then app.module.network else true;
          useStorage = if app.module or { } ? storage then app.module.storage else true;
          useUser = if app.module or { } ? user then app.module.user else true;

          system = pkgs.stdenv.hostPlatform.system;
          output = builder {
            inherit system pkgs app;
            appArgs = (app.getArgs or (_: { })) { inherit pkgs; };
          };

          cfg = nixArgs.config.services.${name};
          defaultEnable =
            if app.module or { } ? defaultEnable then
              app.module.defaultEnable (nixArgs // { inherit cfg; })
            else
              true;
          appOptions =
            if app.module or { } ? options then app.module.options (nixArgs // { inherit cfg; }) else { };

          isLeaf = option: option ? does;
          toNixOptions = builtins.mapAttrs (
            _: opt:
            if isLeaf opt then
              lib.mkOption ({ default = null; } // opt.option // { type = lib.types.nullOr opt.option.type; })
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
                      value = cfg;
                      service = args: { systemd.services.${name} = args; };
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
              enable = lib.mkEnableOption "Enable ${name}." // {
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
                (lib.mkIf useNetwork {
                  systemd.services.${name} = {
                    wants = [ "network-online.target" ];
                    after = [ "network-online.target" ];
                  };
                })
                (lib.mkIf useStorage {
                  systemd.services.${name}.serviceConfig = {
                    WorkingDirectory = "/var/lib/${name}";
                    StateDirectory = name;
                  };
                })
                (lib.mkIf useUser {
                  users.groups.${name} = { };
                  users.users.${name} = lib.mkMerge [
                    {
                      isSystemUser = true;
                      group = name;
                    }
                    (lib.optionalAttrs useStorage {
                      home = "/var/lib/${name}";
                      createHome = true;
                    })
                  ];
                  systemd.services.${name}.serviceConfig = {
                    User = name;
                    Group = name;
                  };
                })
                {
                  systemd.services.${name} = {
                    inherit description;
                    wantedBy = [ "multi-user.target" ];
                    serviceConfig = {
                      ExecStart = "${lib.getExe cfg.package} ${builtins.concatStringsSep " " (builtins.map lib.escapeShellArg cfg.args)}";
                      Restart = lib.mkDefault "on-failure";
                    };
                  };
                }
              ]
              ++ (toNixConfig appOptions cfg)
            )
          );
        };

      defaultDevShellBuildInputs =
        { pkgs }:
        [
          pkgs.git
        ];

      defaultVsCodeExtensions =
        { pkgs }:
        [
          pkgs.vscode-extensions.jnoortheen.nix-ide
        ];

      # A script that updates the dependency lock file of an application and
      # the inputs of its flake. The script runs in the current directory, or
      # in the directory that is passed as its first argument.
      mkUpdate =
        pkgs:
        {
          name,
          command ? "",
          runtimeInputs ? [ ],
        }:
        pkgs.writeShellApplication {
          name = "${name}-update";
          runtimeInputs = runtimeInputs ++ [
            pkgs.git
            pkgs.nix
          ];
          text = ''
            if [ "$#" -gt 0 ]; then
              cd "$1"
            fi

            if [ ! -f flake.nix ]; then
              echo "error: no flake.nix in $PWD, run the update from the root of the flake" >&2
              exit 1
            fi

            ${lib.optionalString (command != "") command}

            nix flake update
          '';
        };

      outputBuilder =
        args: rawApp:
        let
          app = args.appProcess rawApp;
          name = app.name;
          default = app.default or true;
          pkgsImport = app.pkgsImport or { };
          customOutputs = app.outputs or { };
        in
        combine [
          (eachSystem pkgsImport (
            {
              system,
              pkgs,
            }:
            let
              appArgs = (app.getArgs or (_: { })) { inherit pkgs; };
              appArgs' = appArgs // {
                override = appArgs.override or { };
                env = appArgs.env or { };
              };
              output = args.appBuilder {
                inherit system pkgs app;
                appArgs = appArgs';
              };
              src = if app ? src then app.src else (appArgs'.src or null);

              # Environment variables to set on the wrapped binaries.
              env = appArgs'.env or { };

              wrappedPackage =
                output.package.overrideAttrs (
                  old:
                  {
                    passthru = (old.passthru or { }) // (lib.optionalAttrs (output ? extra) output.extra) // (lib.optionalAttrs (output ? update) { inherit (output) update; });
                    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ (lib.optionals (env != { }) [ pkgs.makeWrapper ]);
                    postFixup = (old.postFixup or "") + (lib.optionalString (env != { }) ("\n" + ''
                      if [ -d "$out/bin" ]; then
                        for bin in "$out/bin"/*; do
                          [ -e "$bin" ] || continue
                          if [ -L "$bin" ]; then
                            target="$(readlink -f "$bin")"
                            rm "$bin"
                            cp -L "$target" "$bin"
                            chmod +w "$bin"
                          fi
                          [ -f "$bin" ] && [ -x "$bin" ] || continue
                          wrapProgram "$bin" \
                            ${lib.concatStringsSep " " (
                              lib.mapAttrsToList (
                                key: value:
                                "--set ${lib.escapeShellArg key} ${lib.escapeShellArg (toString value)}"
                              ) env
                            )}
                        done
                      fi
                    ''));
                  });
              output' = output // { package = wrappedPackage; };
              custom = lib.mapAttrs (
                key: builder:
                let
                  result = builder {
                    inherit
                      pkgs
                      system
                      app
                      appArgs
                      src
                      ;
                    package = output'.package;
                    check = output'.check or null;
                  };
                in
                # A derivation is a package, an attribute set with a
                # `check` and/or a `package` attribute defines both of
                # them separately.
                if isDerivation result then
                  { package = result; }
                else if builtins.isAttrs result && (result ? package || result ? check) then
                  result
                else
                  { package = result; }
              ) customOutputs;
              customChecks = lib.filterAttrs (_: value: value ? check) custom;
              customPackages = lib.filterAttrs (_: value: value ? package) custom;
            in
            {
              checks.${system} =
                (if output' ? check then { ${name} = output'.check; } else { })
                // lib.mapAttrs' (key: value: lib.nameValuePair "${name}-${key}" value.check) customChecks;

              packages.${system} = {
                ${name} = output'.package;
              }
              // lib.mapAttrs' (key: value: lib.nameValuePair "${name}-${key}" value.package) customPackages
              // (if default then { default = output'.package; } else { });

              formatter.${system} =
                if output' ? formatter then { ${name} = output'.formatter; } else { };

              devShells.${system} = {
                ${name} = output'.devShell;
              }
              // (if default then { default = output'.devShell; } else { });
            }
          ))
          (
            let
              enableModule = if app.module or { } ? enable then app.module.enable else true;
              module =
                { pkgs, ... }@nixArgs:
                defaultModule {
                  inherit app nixArgs;
                  builder = args.appBuilder;
                };
            in
            if enableModule then
              {
                nixosModules = {
                  ${name} = module;
                }
                // (if default then { default = module; } else { });
              }
            else
              { }
          )
        ];

      rustApp =
        {
          system,
          pkgs,
          app,
          appArgs,
        }:
        let
          name = app.name;
          version = app.version;
          crateName = app.crateName or name;
          implementation = app.implementation or "crate2nix";
          src = if app ? src then app.src else (appArgs.src or null);
          override = appArgs.override or { };
          craneLib = inputs.crane.mkLib pkgs;

          resolve =
            scope: defaults:
            resolveOverrides {
              inherit
                override
                scope
                implementation
                defaults
                ;
              specialArgs = implementationSpecialArgs.${implementation} or { };
            };

          # Arguments accepted by the `build` step of the crate2nix build.
          crate2nixArgs = [
            "features"
            "runTests"
            "testCrateFlags"
            "testInputs"
            "testPreRun"
            "testPostRun"
          ];

          crate2nixBuild =
            scope:
            let
              resolved = resolve scope {
                build = {
                  runTests = scope == "check";
                };
              };
              args = resolved.stepArgs.build;
              # The arguments that the `build` step does not accept are
              # applied to the crate of the application, like the generic
              # arguments.
              generic = mergeValues {
                prev = resolved.genericArgs;
                next = lib.filterAttrs (key: _: !(builtins.elem key crate2nixArgs) && key != "crateOverrides") args;
                extendLists = true;
              };
              userOverrides = args.crateOverrides or { };
              combined = pkgs.defaultCrateOverrides // userOverrides;
              rootOverride = combined.${crateName} or (attrs: attrs);
              crateOverrides =
                if generic == { } then
                  (if userOverrides == { } then { } else combined)
                else
                  combined
                  // {
                    ${crateName} =
                      attrs:
                      mergeValues {
                        prev = rootOverride attrs;
                        next = generic;
                        extendLists = true;
                      };
                  };
            in
            lib.filterAttrs (key: _: builtins.elem key crate2nixArgs) args
            // (if crateOverrides == { } then { } else { inherit crateOverrides; });

          naerskBuild =
            scope:
            let
              resolved = resolve scope {
                buildPackage = {
                  inherit name src;
                  mode = if scope == "check" then "test" else "build";
                };
              };
            in
            mergeValues {
              prev = resolved.stepArgs.buildPackage;
              next = resolved.genericArgs;
              extendLists = true;
            };

          craneBuild =
            scope:
            let
              resolved = resolve scope {
                buildPackage = {
                  src = craneLib.cleanCargoSource src;
                  strictDeps = true;
                  doCheck = scope == "check";
                };
                buildDepsOnly = { };
              };
              packageArgs = mergeValues {
                prev = resolved.stepArgs.buildPackage;
                next = resolved.genericArgs;
                extendLists = true;
              };
              depsArgs = mergeValues {
                prev = packageArgs;
                next = resolved.stepArgs.buildDepsOnly;
              };
              cargoArtifacts = packageArgs.cargoArtifacts or (craneLib.buildDepsOnly depsArgs);
            in
            packageArgs // { inherit cargoArtifacts; };

          buildRustPackageBuild =
            scope:
            let
              rustPlatform = appArgs.rustPlatform or pkgs.rustPlatform;
              resolved = resolve scope {
                buildPackage = {
                  inherit name version src;
                  doCheck = scope == "check";
                };
              };
            in
            rustPlatform.buildRustPackage (mergeValues {
              prev = resolved.stepArgs.buildPackage;
              next = resolved.genericArgs;
              extendLists = true;
            });

          devShell =
            let
              resolved = resolve "devshell" {
                shell = {
                  buildInputs = (defaultDevShellBuildInputs { inherit pkgs; }) ++ [
                    pkgs.cargo
                    pkgs.rustc
                    pkgs.rustfmt
                    pkgs.clippy

                    (pkgs.vscode-with-extensions.override {
                      vscode = pkgs.vscode;
                      vscodeExtensions = (defaultVsCodeExtensions { inherit pkgs; }) ++ [
                        pkgs.vscode-extensions.rust-lang.rust-analyzer
                        pkgs.vscode-extensions.tamasfe.even-better-toml
                      ];
                    })
                  ];
                  RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
                  shellHook = ''
                    code .
                  '';
                };
              };
            in
            pkgs.mkShell (mergeValues {
              prev = resolved.stepArgs.shell;
              next = resolved.genericArgs;
              extendLists = true;
            });
        in
        (
          if implementation == "crate2nix" then
            let
              build =
                (inputs.crate2nix.tools.${system}.appliedCargoNix {
                  inherit name src;
                }).rootCrate.build;
            in
            {
              check = build.override (crate2nixBuild "check");

              package = build.override (crate2nixBuild "package");
            }
          else if implementation == "naersk" then
            let
              naersk' = pkgs.callPackage inputs.naersk { };
            in
            {
              check = naersk'.buildPackage (naerskBuild "check");

              package = naersk'.buildPackage (naerskBuild "package");
              extra = {
                inherit appArgs naersk';
              };
            }
          else if implementation == "crane" then
            let
              craneBuildResult =
                scope:
                let
                  resolved = resolve scope {
                    buildPackage = {
                      src = craneLib.cleanCargoSource src;
                      strictDeps = true;
                      doCheck = scope == "check";
                    };
                    buildDepsOnly = { };
                  };
                  packageArgs = mergeValues {
                    prev = resolved.stepArgs.buildPackage;
                    next = resolved.genericArgs;
                    extendLists = true;
                  };
                  depsArgs = mergeValues {
                    prev = packageArgs;
                    next = resolved.stepArgs.buildDepsOnly;
                  };
                  cargoArtifacts = packageArgs.cargoArtifacts or (craneLib.buildDepsOnly depsArgs);
                in
                {
                  args = packageArgs // { inherit cargoArtifacts; };
                  inherit cargoArtifacts;
                };
            in
            {
              check = craneLib.buildPackage (craneBuildResult "check").args;
              package = craneLib.buildPackage (craneBuildResult "package").args;
              extra = {
                inherit appArgs craneLib;
                cargoArtifacts = (craneBuildResult "package").cargoArtifacts;
              };
            }
          else if implementation == "buildRustPackage" then
            {
              check = buildRustPackageBuild "check";

              package = buildRustPackageBuild "package";
              extra = {
                inherit appArgs;
              };
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          inherit devShell;
          update = mkUpdate pkgs {
            inherit name;
            command = "cargo update";
            runtimeInputs = [ pkgs.cargo ];
          };
          formatter =
            pkgs.writeShellApplication {
              name = "${name}-formatter";
              runtimeInputs = [ pkgs.rustfmt pkgs.cargo ];
              text = ''
                if [ "$#" -gt 0 ]; then
                  cd "$1"
                fi
                cargo fmt
              '';
            };
        };

      pythonApp =
        {
          system,
          pkgs,
          app,
          appArgs,
        }:
        let
          name = app.name;
          version = app.version;
          src = if app ? src then app.src else (appArgs.src or null);
          type = app.type or (if builtins.pathExists (src + "/uv.lock") then "uv" else "");
          implementation = app.implementation or (if type == "uv" then "uv2nix" else "pyproject.nix");
          override = appArgs.override or { };
          python = appArgs.python or pkgs.python3;

          resolve =
            scope: defaults:
            resolveOverrides {
              inherit
                override
                scope
                implementation
                defaults
                ;
              specialArgs = implementationSpecialArgs.${implementation} or { };
            };

          devShell =
            let
              resolved = resolve "devshell" {
                shell = {
                  buildInputs =
                    (defaultDevShellBuildInputs { inherit pkgs; })
                    ++ [
                      (pkgs.vscode-with-extensions.override {
                        vscode = pkgs.vscode;
                        vscodeExtensions = (defaultVsCodeExtensions { inherit pkgs; }) ++ [
                          pkgs.vscode-extensions.ms-python.python
                        ];
                      })
                    ]
                    ++ (
                      if type == "uv" then
                        [ pkgs.uv ]
                      else if type == "poetry" then
                        [ pkgs.poetry ]
                      else
                        [ pkgs.python ]
                    );
                  shellHook = ''
                    code .
                  '';
                };
              };
            in
            pkgs.mkShell (mergeValues {
              prev = resolved.stepArgs.shell;
              next = resolved.genericArgs;
              extendLists = true;
            });
        in
        (
          if implementation == "pyproject.nix" then
            let
              loader =
                if type == "uv" then
                  "loadUVPyproject"
                else if type == "poetry" then
                  "loadPoetryPyproject"
                else
                  "loadPyproject";
              extraRequirements = appArgs.extraRequirements or [ ];
              pyproject = pkgs.lib.importTOML (src + (appArgs.pyproject or "/pyproject.toml"));
              baseProject = inputs.pyproject-nix.lib.project.${loader} ({
                inherit pyproject;
                projectRoot = src;
              });
              finalDependencies =
                (builtins.map (
                  requirement:
                  (inputs.pyproject-nix.lib.project.loadRequirementsTxt {
                    requirements =
                      let
                        processRequirements =
                          path:
                          let
                            parentFolder = builtins.dirOf path;
                            rawContent = builtins.readFile path;
                            perLine = pkgs.lib.splitString "\n" rawContent;
                            patchedLines = builtins.map (
                              line:
                              let
                                readFile = pkgs.lib.splitString "-r " line;
                              in
                              if line != "" && builtins.elemAt readFile 0 == "" then
                                processRequirements "${parentFolder}/${builtins.elemAt readFile 1}"
                              else
                                line
                            ) perLine;
                          in
                          builtins.concatStringsSep "\n" patchedLines;
                      in
                      processRequirements (src + "/${requirement}");
                  }).dependencies.dependencies
                ) extraRequirements)
                ++ [ baseProject.dependencies.dependencies ];
              project = baseProject // {
                dependencies = baseProject.dependencies // {
                  dependencies = builtins.concatLists finalDependencies;
                };
              };
              buildPythonPackage' =
                scope:
                let
                  resolved = resolve scope {
                    buildPythonPackage = {
                      inherit version;
                      pname = name;
                      pythonRelaxDeps = true;
                      doCheck = scope == "check";
                    }
                    // (
                      if scope == "check" then
                        {
                          nativeCheckInputs = [ python.pkgs.pytestCheckHook ];
                        }
                      else
                        { }
                    );
                  };
                in
                python.pkgs.buildPythonPackage (
                  (inputs.pyproject-nix.lib.renderers.buildPythonPackage { inherit python project; })
                  // (mergeValues {
                    prev = resolved.stepArgs.buildPythonPackage;
                    next = resolved.genericArgs;
                    extendLists = true;
                  })
                );
            in
            {
              check = buildPythonPackage' "check";
              package = buildPythonPackage' "package";
              extra = {
                inherit appArgs project;
              };
            }
          else if implementation == "uv2nix" then
            let
              workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = src; };
              overlay = workspace.mkPyprojectOverlay {
                sourcePreference = "wheel";
              };
              resolvedPackage = resolve "package" {
                pythonSet = { };
                venv = {
                  venvIgnoreCollisions = [ "*" ];
                };
                application = { };
              };
              resolvedCheck = resolve "check" {
                pythonSet = { };
                venv = {
                  venvIgnoreCollisions = [ "*" ];
                };
                application = { };
              };
              # Build the Python package of a scope. The `check` scope of
              # `uv2nix` builds the package of the application with the same
              # steps as the `package` scope, the generic arguments are
              # therefore shared by both scopes.
              mkPythonSet =
                resolved:
                (pkgs.callPackage inputs.pyproject-nix.build.packages {
                  inherit python;
                }).overrideScope
                  (
                    pkgs.lib.composeManyExtensions ([
                      inputs.pyproject-build-systems.overlays.wheel
                      overlay
                      (resolved.stepArgs.pythonSet.override or (final: prev: { }))
                    ])
                  );
              mkPackage =
                resolved:
                let
                  pythonSet = mkPythonSet resolved;
                  generic = resolved.genericArgs;
                  package =
                    if generic == { } then
                      pythonSet.${name}
                    else
                      pythonSet.${name}.overrideAttrs (
                        old:
                        lib.filterAttrs (key: _: builtins.hasAttr key generic) (mergeValues {
                          prev = old;
                          next = generic;
                          extendLists = true;
                        })
                      );
                  venv = (pythonSet.mkVirtualEnv "${name}-${version}-venv" workspace.deps.default).overrideAttrs (
                    old: resolved.stepArgs.venv
                  );
                  application = (pkgs.callPackages inputs.pyproject-nix.build.util { }).mkApplication {
                    inherit venv package;
                  };
                in
                {
                  inherit pythonSet venv package;
                  result = application.overrideAttrs (old: resolved.stepArgs.application);
                };
              pythonPackage = mkPackage resolvedPackage;
              pythonPackageCheck = mkPackage resolvedCheck;
            in
            {
              check = pythonPackageCheck.result;
              package = pythonPackage.result;

              extra = {
                inherit
                  appArgs
                  overlay
                  ;
                pythonSet = pythonPackage.pythonSet;
                venv = pythonPackage.venv;
              };
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          inherit devShell;
          update = mkUpdate pkgs {
            inherit name;
            # `pyproject.nix` builds the package without a lock file, only
            # the package managers that write one can update the
            # dependencies of the application.
            command =
              if type == "uv" then
                "uv lock --upgrade"
              else if type == "poetry" then
                "poetry update"
              else
                "";
            runtimeInputs =
              if type == "uv" then
                [ pkgs.uv ]
              else if type == "poetry" then
                [ pkgs.poetry ]
              else
                [ ];
          };
          formatter =
            if type == "uv" then
              pkgs.writeShellApplication {
                name = "${name}-formatter";
                runtimeInputs = [ pkgs.ruff ];
                text = ''
                  if [ "$#" -gt 0 ]; then
                    cd "$1"
                  fi
                  ruff format .
                  ruff check --fix .
                '';
              }
            else if type == "poetry" then
              pkgs.writeShellApplication {
                name = "${name}-formatter";
                runtimeInputs = [ pkgs.black pkgs.isort ];
                text = ''
                  if [ "$#" -gt 0 ]; then
                    cd "$1"
                  fi
                  black .
                  isort .
                '';
              }
            else
              pkgs.writeShellApplication {
                name = "${name}-formatter";
                runtimeInputs = [ pkgs.black ];
                text = ''
                  if [ "$#" -gt 0 ]; then
                    cd "$1"
                  fi
                  black .
                '';
              };
        };

      goApp =
        {
          system,
          pkgs,
          app,
          appArgs,
        }:
        let
          name = app.name;
          version = app.version;
          src = if app ? src then app.src else (appArgs.src or null);
          implementation = app.implementation or "buildGoModule";
          override = appArgs.override or { };

          resolve =
            scope: defaults:
            resolveOverrides {
              inherit
                override
                scope
                implementation
                defaults
                ;
              specialArgs = implementationSpecialArgs.${implementation} or { };
            };

          goBuild =
            scope:
            let
              resolved = resolve scope {
                buildGoModule = {
                  pname = name;
                  inherit version src;
                  vendorHash = pkgs.lib.fakeHash;
                  doCheck = scope == "check";
                  meta = {
                    mainProgram = name;
                  };
                };
              };
            in
            pkgs.buildGoModule (mergeValues {
              prev = resolved.stepArgs.buildGoModule;
              next = resolved.genericArgs;
              extendLists = true;
            });

          devShell =
            let
              resolved = resolve "devshell" {
                shell = {
                  buildInputs = (defaultDevShellBuildInputs { inherit pkgs; }) ++ [
                    pkgs.go

                    (pkgs.vscode-with-extensions.override {
                      vscode = pkgs.vscode;
                      vscodeExtensions = (defaultVsCodeExtensions { inherit pkgs; }) ++ [
                        pkgs.vscode-extensions.golang.go
                      ];
                    })
                  ];
                  shellHook = ''
                    code .
                  '';
                };
              };
            in
            pkgs.mkShell (mergeValues {
              prev = resolved.stepArgs.shell;
              next = resolved.genericArgs;
              extendLists = true;
            });
        in
        (
          if implementation == "buildGoModule" then
            {
              check = goBuild "check";

              package = goBuild "package";
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          inherit devShell;
          update = mkUpdate pkgs {
            inherit name;
            command = ''
              go get -u ./...
              go mod tidy
            '';
            runtimeInputs = [ pkgs.go ];
          };
          formatter =
            pkgs.writeShellApplication {
              name = "${name}-formatter";
              runtimeInputs = [ pkgs.gofmt ];
              text = ''
                if [ "$#" -gt 0 ]; then
                  cd "$1"
                fi
                gofmt -w .
              '';
            };
        };

      javascriptApp =
        {
          system,
          pkgs,
          app,
          appArgs,
        }:
        let
          name = app.name;
          version = app.version;
          src = if app ? src then app.src else (appArgs.src or null);
          type =
            app.type or (
              if builtins.pathExists (src + "/package-lock.json") then
                "npm"
              else if builtins.pathExists (src + "/yarn.lock") then
                "yarn"
              else if builtins.pathExists (src + "/pnpm-lock.yaml") then
                "pnpm"
              else if builtins.pathExists (src + "/bun.lock") then
                "bun"
              else
                ""
            );
          implementation = app.implementation or "buildNpmPackage";
          packageJson =
            if builtins.pathExists (src + "/package.json") then
              builtins.fromJSON (builtins.readFile (src + "/package.json"))
            else
              { };
          # The command of the `test` script of the package, if it has one.
          testCommand =
            if type == "npm" then
              "npm run test"
            else if type == "yarn" then
              "yarn run test"
            else if type == "pnpm" then
              "pnpm run test"
            else if type == "bun" then
              "bun run test"
            else
              "";
          framework =
            app.framework or (
              if
                builtins.pathExists (src + "/next.config.js")
                || builtins.pathExists (src + "/next.config.ts")
                || builtins.pathExists (src + "/next.config.mjs")
                || builtins.pathExists (src + "/next.config.cjs")
              then
                "nextjs"
              else if
                builtins.pathExists (src + "/vite.config.js")
                || builtins.pathExists (src + "/vite.config.ts")
                || builtins.pathExists (src + "/vite.config.mjs")
                || builtins.pathExists (src + "/vite.config.cjs")
              then
                "vite"
              else if
                builtins.pathExists (src + "/astro.config.js")
                || builtins.pathExists (src + "/astro.config.ts")
                || builtins.pathExists (src + "/astro.config.mjs")
                || builtins.pathExists (src + "/astro.config.cjs")
              then
                "astro"
              else
                ""
            );
          override = appArgs.override or { };

          resolve =
            scope: defaults:
            resolveOverrides {
              inherit
                override
                scope
                implementation
                defaults
                ;
              specialArgs = implementationSpecialArgs.${implementation} or { };
            };

          installArgs =
            (
              if framework == "nextjs" then
                {
                  copy = [
                    ".next"
                    "public"
                    "node_modules"
                    "package.json"
                  ];
                  execute = args: "cd ${args.dir} && ${args.npm} run start";
                  commands = ''
                    # https://github.com/vercel/next.js/discussions/58864
                    ln -s /var/cache/${name} $out/share/.next/cache
                  '';
                }
              else if framework == "vite" || framework == "astro" then
                {
                  copy = [ "dist" ];
                  execute = args: "${pkgs.lib.getExe pkgs.static-web-server} --port 3000 --root ${args.dir}/dist";
                }
              else if framework == "react" then
                {
                  copy = [ "build" ];
                  execute = args: "${pkgs.lib.getExe pkgs.static-web-server} --port 3000 --root ${args.dir}/build";
                }
              else if framework == "nextjs-standalone" then
                {
                  copy = [
                    ".next"
                    "public"
                  ];
                  execute = args: "${args.node} ${args.dir}/server.js";
                  commands = ''
                    # https://github.com/vercel/next.js/discussions/58864
                    ln -s /var/cache/${name} $out/share/.next/cache
                    mv $out/share/.next/standalone/* $out/share
                  '';
                }
              else if framework == "astro-node" then
                {
                  copy = [
                    "dist"
                    "node_modules"
                  ];
                  execute = args: "${args.node} ${args.dir}/dist/server/entry.mjs";
                }
              else if framework == "astro-node-noext" then
                {
                  copy = [ "dist" ];
                  execute = args: "${args.node} ${args.dir}/dist/server/entry.mjs";
                }
              else
                { }
            )
            // (appArgs.frameworkArgs or { });

          devShell =
            let
              resolved = resolve "devshell" {
                shell = {
                  buildInputs =
                    (defaultDevShellBuildInputs { inherit pkgs; })
                    ++ [
                      pkgs.python

                      (pkgs.vscode-with-extensions.override {
                        vscode = pkgs.vscode;
                        vscodeExtensions =
                          (defaultVsCodeExtensions { inherit pkgs; })
                          ++ [
                            pkgs.vscode-extensions.ms-python.python
                          ]
                          ++ (
                            if framework == "vite" then
                              [ pkgs.vscode-extensions.vue.volar ]
                            else if framework == "astro" || framework == "astro-node" then
                              [ pkgs.vscode-extensions.astro-build.astro-vscode ]
                            else
                              [ ]
                          );
                      })
                    ]
                    ++ (
                      if type == "npm" then
                        [ pkgs.nodejs ]
                      else if type == "yarn" then
                        [ pkgs.yarn ]
                      else if type == "pnpm" then
                        [ pkgs.pnpm ]
                      else if type == "bun" then
                        [ pkgs.bun ]
                      else
                        [ ]
                    );
                  shellHook = ''
                    code .
                  '';
                };
              };
            in
            pkgs.mkShell (mergeValues {
              prev = resolved.stepArgs.shell;
              next = resolved.genericArgs;
              extendLists = true;
            });
        in
        (
          if implementation == "buildNpmPackage" then
            let
              npmBuild =
                scope:
                let
                  resolved = resolve scope {
                    buildNpmPackage = {
                      pname = name;
                      inherit version src;
                      meta = {
                        mainProgram = name;
                      };
                      doCheck = scope == "check" && packageJson.scripts ? test;
                      installPhase = ''
                        runHook preInstall

                        mkdir -p $out/{share,bin}
                        ${builtins.concatStringsSep "\n" (
                          builtins.map (toCopy: "cp --parents -r ${toCopy} $out/share") installArgs.copy or [ ]
                        )}
                        cat > $out/bin/${name} << EOF
                        #!${pkgs.lib.getExe pkgs.bash}
                        ${(installArgs.execute or (args: "")) {
                          node =
                            if type == "npm" then
                              pkgs.lib.getExe pkgs.nodejs
                            else if type == "yarn" then
                              pkgs.lib.getExe pkgs.yarn
                            else if type == "pnpm" then
                              pkgs.lib.getExe pkgs.pnpm
                            else if type == "bun" then
                              pkgs.lib.getExe pkgs.bun
                            else
                              "";
                          npm =
                            if type == "npm" then
                              pkgs.lib.getExe' pkgs.nodejs "npm"
                            else if type == "yarn" then
                              pkgs.lib.getExe pkgs.yarn
                            else if type == "pnpm" then
                              pkgs.lib.getExe pkgs.pnpm
                            else if type == "bun" then
                              pkgs.lib.getExe pkgs.bun
                            else
                              "";
                          dir = "$out/share";
                        }}
                        EOF
                        chmod +x $out/bin/${name}
                        ${installArgs.commands or ""}
                        ${installArgs.extraCommands or ""}

                        runHook postInstall
                      '';
                    }
                    // (
                      if type == "npm" then
                        {
                          npmDeps = pkgs.importNpmLock {
                            pname = name;
                            inherit version;
                            npmRoot = src;
                          };
                          npmConfigHook = pkgs.importNpmLock.npmConfigHook;
                        }
                      else
                        { }
                    )
                    // (
                      # `buildNpmPackage` does not run the tests of the
                      # package, the check scope adds a check phase that
                      # runs the `test` script of the package.
                      if scope == "check" && packageJson.scripts ? test then
                        {
                          checkPhase = ''
                            runHook preCheck

                            ${testCommand}

                            runHook postCheck
                          '';
                        }
                      else
                        { }
                    );
                  };
                in
                pkgs.buildNpmPackage (mergeValues {
                  prev = resolved.stepArgs.buildNpmPackage;
                  next = resolved.genericArgs;
                  extendLists = true;
                });
            in
            {
              check = npmBuild "check";
              package = npmBuild "package";
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          inherit devShell;
          update = mkUpdate pkgs {
            inherit name;
            command =
              if type == "npm" then
                "npm update"
              else if type == "yarn" then
                "yarn upgrade"
              else if type == "pnpm" then
                "pnpm update"
              else if type == "bun" then
                "bun update"
              else
                "";
            runtimeInputs =
              if type == "npm" then
                [ pkgs.nodejs ]
              else if type == "yarn" then
                [ pkgs.yarn ]
              else if type == "pnpm" then
                [ pkgs.pnpm ]
              else if type == "bun" then
                [ pkgs.bun ]
              else
                [ ];
          };
          formatter =
            if type == "bun" then
              pkgs.writeShellApplication {
                name = "${name}-formatter";
                runtimeInputs = [ pkgs.bun ];
                text = ''
                  if [ "$#" -gt 0 ]; then
                    cd "$1"
                  fi
                  bunx prettier --write . || bunx biome format --write . || true
                '';
              }
            else if type == "pnpm" then
              pkgs.writeShellApplication {
                name = "${name}-formatter";
                runtimeInputs = [ pkgs.pnpm pkgs.nodejs ];
                text = ''
                  if [ "$#" -gt 0 ]; then
                    cd "$1"
                  fi
                  pnpm exec prettier --write . || pnpm exec biome format --write . || true
                '';
              }
            else if type == "yarn" then
              pkgs.writeShellApplication {
                name = "${name}-formatter";
                runtimeInputs = [ pkgs.yarn pkgs.nodejs ];
                text = ''
                  if [ "$#" -gt 0 ]; then
                    cd "$1"
                  fi
                  yarn exec prettier --write . || yarn exec biome format --write . || true
                '';
              }
            else
              pkgs.writeShellApplication {
                name = "${name}-formatter";
                runtimeInputs = [ pkgs.nodejs ];
                text = ''
                  if [ "$#" -gt 0 ]; then
                    cd "$1"
                  fi
                  npx prettier --write . || npx biome format --write . || true
                '';
              };
        };
      language =
        let
          rust = outputBuilder {
            appBuilder = rustApp;
            appProcess =
              app:
              let
                metadata =
                  if app ? src then builtins.fromTOML (builtins.readFile (app.src + "/Cargo.toml")) else { };
                processed = {
                  name = metadata.package.name or "rust-app";
                  version = metadata.package.version or "1.0.0";
                }
                // app;
              in
              processed // { crateName = processed.crateName or processed.name; };
          };
          python = outputBuilder {
            appBuilder = pythonApp;
            appProcess =
              app:
              let
                metadata =
                  if app ? src then builtins.fromTOML (builtins.readFile (app.src + "/pyproject.toml")) else { };
                processed = {
                  name = metadata.project.name or "python-app";
                  version = metadata.project.version or "1.0.0";
                }
                // app;
              in
              processed;
          };
          go = outputBuilder {
            appBuilder = goApp;
            appProcess =
              app:
              {
                name = "go-app";
                version = "1.0.0";
              }
              // app;
          };
          javascript = outputBuilder {
            appBuilder = javascriptApp;
            appProcess =
              app:
              let
                metadata =
                  if app ? src then builtins.fromJSON (builtins.readFile (app.src + "/package.json")) else { };
                processed = {
                  name = metadata.name or "javascript-app";
                  version = metadata.version or "1.0.0";
                }
                // app;
              in
              processed;
          };
        in
        {
          inherit
            rust
            python
            go
            javascript
            ;

          auto =
            app:
            if builtins.pathExists (app.src + "/Cargo.toml") then
              rust app
            else if builtins.pathExists (app.src + "/pyproject.toml") then
              python app
            else if builtins.pathExists (app.src + "/go.mod") then
              go app
            else if builtins.pathExists (app.src + "/package.json") then
              javascript app
            else
              builtins.throw "Could not detect language";
        };
    in
    {
      inherit language;

      combine = combine;

      templates = {
        rust = {
          description = "A Rust application built with Cargo.";
          path = ./templates/rust/hello-world;
        };
        poetry = {
          description = "A Python application built with Poetry.";
          path = ./templates/python/poetry;
        };
        uv = {
          description = "A Python application built with uv.";
          path = ./templates/python/uv;
        };
        go = {
          description = "A Go application with dependencies.";
          path = ./templates/go/dependency;
        };
        nodejs = {
          description = "A Node.js application.";
          path = ./templates/javascript/nodejs;
        };
        nextjs = {
          description = "A Next.js application.";
          path = ./templates/javascript/nextjs;
        };
        vite = {
          description = "A Vite application.";
          path = ./templates/javascript/vite;
        };
        astro = {
          description = "An Astro application.";
          path = ./templates/javascript/astro;
        };
        react = {
          description = "A React application.";
          path = ./templates/javascript/react;
        };
      };

      # ==================================================================
      # Tests
      # ==================================================================
      #
      # The tests assert the behavior of the override system and of the
      # custom outputs. They never build the app, they only inspect the
      # evaluated outputs. Every assertion is turned into a derivation that
      # fails when the condition does not hold.
      checks = eachSystemBySystem { } (
        {
          system,
          pkgs,
        }:
        let
          assertions = lib.mapAttrs (
            name: condition:
            pkgs.runCommand "xnode-builders-test-${name}" { } (
              if condition then
                ''
                  echo "Test passed: ${name}"
                  touch $out
                ''
              else
                ''
                  echo "Test failed: ${name}" >&2
                  exit 1
                ''
            )
          );

          # The names of the build inputs of a derivation.
          inputNames =
            derivation: map (input: input.pname or input.name or "?") (derivation.drvAttrs.buildInputs or [ ]);

          # The app with an override tree that covers every layer.
          overridden = language.rust {
            src = ./tests/rust;
            implementation = "buildRustPackage";
            override =
              {
                pkgs,
                ...
              }:
              {
                # A generic argument for every scope and implementation.
                common.common.buildInputs = [ pkgs.hello ];
                # An argument of a build step for every scope.
                common.buildRustPackage.buildPackage.cargoBuildFlags = [ "--locked" ];
                # A generic argument for the package scope.
                package.common.buildInputs = prev: prev ++ [ pkgs.cowsay ];
                # An argument of a build step for the package scope.
                package.buildRustPackage.buildPackage.buildInputs = [ pkgs.coreutils ];
                # An argument of a build step for the check scope.
                check.buildRustPackage.buildPackage.doCheck = true;
                # An argument of the development shell.
                devshell.common.shell.buildInputs = prev: prev ++ [ pkgs.gnugrep ];
              };
          };

          package = overridden.packages.${system}.test-app;
          check = overridden.checks.${system}.test-app;
          shell = overridden.devShells.${system}.test-app;

          # The app with custom outputs.
          withOutputs = language.rust {
            src = ./tests/rust;
            implementation = "buildRustPackage";
            outputs = {
              # A custom output that only adds a check.
              extra-check =
                {
                  pkgs,
                  ...
                }:
                {
                  check = pkgs.runCommand "extra-check" { } ''
                    touch $out
                  '';
                };

              # A custom output that only adds a package. It receives
              # the package of the app.
              extra-package =
                {
                  pkgs,
                  package,
                  ...
                }:
                pkgs.runCommand "extra-package" { inherit package; } ''
                  touch $out
                '';

              # A custom output that adds a check and a package.
              both =
                {
                  pkgs,
                  ...
                }:
                {
                  check = pkgs.runCommand "both-check" { } ''
                    touch $out
                  '';
                  package = pkgs.runCommand "both-package" { } ''
                    touch $out
                  '';
                };
            };
          };

          # The app of the crate2nix implementation. The Cargo.nix file of
          # the application is generated with an import from derivation,
          # which is only possible on the system of the machine that builds
          # the derivations. The current system is only known in impure
          # mode, so these tests are only run with `nix flake check
          # --impure`.
          crate2nix =
            if builtins ? currentSystem && system == builtins.currentSystem then
              language.rust {
                src = ./tests/rust;
                implementation = "crate2nix";
                override = {
                  # A generic argument for every scope and implementation.
                  common.common.buildInputs = [ pkgs.hello ];
                  # An argument of the build step of the crate2nix
                  # implementation.
                  package.crate2nix.build.features = [ "default" ];
                  # An argument that the build step does not accept, it is
                  # applied to the crate of the application.
                  package.crate2nix.build.buildInputs = [ pkgs.coreutils ];
                  # An argument of the tests of the crate2nix
                  # implementation.
                  check.crate2nix.build.testInputs = [ pkgs.coreutils ];
                };
              }
            else
              null;

          # The Python app of the `pyproject.nix` implementation. The
          # check scope builds the package with its tests.
          python = language.python {
            src = ./tests/python;
            implementation = "pyproject.nix";
          };

          # The JavaScript app. The check scope runs the `test` script of
          # the package.
          javascript = language.javascript {
            src = ./tests/javascript;
          };
        in
        assertions (
          {
            # The generic argument of `common.common` is applied to every
            # scope.
            "generic-argument-common" =
              inputNames package == [
                "coreutils"
                "hello"
                "cowsay"
              ];

            # The generic argument of the package scope is not applied to the
            # check scope.
            "generic-argument-scope" = inputNames check == [ "hello" ];

            # The argument of the build step is applied to every scope.
            "step-argument-common" =
              package.drvAttrs.cargoBuildFlags == [ "--locked" ]
              && check.drvAttrs.cargoBuildFlags == [ "--locked" ];

            # The argument of the build step of the check scope is only
            # applied to the check scope.
            "step-argument-scope" = check.drvAttrs.doCheck == true && package.drvAttrs.doCheck == false;

            # The development shell keeps its default inputs and gets the
            # additional ones.
            "devshell-argument" =
              builtins.elem "gnugrep" (map (input: input.pname or input.name or "?") shell.buildInputs)
              && builtins.elem "cargo" (map (input: input.pname or input.name or "?") shell.buildInputs)
              && builtins.elem "hello" (map (input: input.pname or input.name or "?") shell.buildInputs);

            # The custom outputs are exposed as checks and packages.
            "custom-output-check" =
              builtins.hasAttr "test-app-extra-check" withOutputs.checks.${system}
              && !(builtins.hasAttr "test-app-extra-check" withOutputs.packages.${system});
            "custom-output-package" =
              builtins.hasAttr "test-app-extra-package" withOutputs.packages.${system}
              && !(builtins.hasAttr "test-app-extra-package" withOutputs.checks.${system});
            "custom-output-both-check" = builtins.hasAttr "test-app-both" withOutputs.checks.${system};
            "custom-output-both-package" = builtins.hasAttr "test-app-both" withOutputs.packages.${system};

            # The custom output receives the package of the app.
            "custom-output-arguments" =
              withOutputs.packages.${system}.test-app-extra-package.drvAttrs.package.drvAttrs.name
              == withOutputs.packages.${system}.test-app.drvAttrs.name;

            # The check scope of the Python implementation runs the tests
            # of the package, the package scope does not.
            "python-check-argument" =
              python.checks.${system}.test-app.drvAttrs.doInstallCheck == true
              && python.packages.${system}.test-app.drvAttrs.doInstallCheck == false;

            # The check scope of the Python implementation adds the pytest
            # hook to the build, the package scope does not.
            "python-check-inputs" =
              builtins.elem "pytest-check-hook" (
                map (
                  input: input.name or input.pname or "?"
                ) python.checks.${system}.test-app.drvAttrs.nativeBuildInputs
              )
              && !(builtins.elem "pytest-check-hook" (
                map (
                  input: input.name or input.pname or "?"
                ) python.packages.${system}.test-app.drvAttrs.nativeBuildInputs
              ));

            # The check scope of the JavaScript implementation runs the
            # `test` script of the package, the package scope does not.
            "javascript-check-argument" =
              javascript.checks.${system}.test-app.drvAttrs.doCheck == true
              && javascript.packages.${system}.test-app.drvAttrs.doCheck == false;

            # The JavaScript implementation has no built-in check phase, the
            # check scope adds one.
            "javascript-check-phase" =
              javascript.checks.${system}.test-app.drvAttrs ? checkPhase
              && !(javascript.packages.${system}.test-app.drvAttrs ? checkPhase);
          }
          // (
            if crate2nix == null then
              { }
            else
              {
                # The arguments of the build step of the crate2nix
                # implementation are applied to the crate.
                "crate2nix-step-argument" =
                  crate2nix.packages.${system}.test-app.drvAttrs.crateFeatures == [ "default" ];

                # The generic arguments are applied to the crate of the
                # application.
                "crate2nix-generic-argument" =
                  inputNames crate2nix.packages.${system}.test-app == [
                    "hello"
                    "coreutils"
                  ];

                # The arguments of the tests are applied to the crate of the
                # tests.
                "crate2nix-test-argument" =
                  inputNames crate2nix.checks.${system}.test-app.passthru.test == [ "coreutils" ];
              }
          )
        )
      );
    };
}
