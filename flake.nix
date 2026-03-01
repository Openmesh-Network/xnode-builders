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
        f:
        combine (
          builtins.map (
            system:
            f {
              inherit system;
              pkgs = import inputs.nixpkgs {
                inherit system;
                config.allowUnfree = true;
              };
            }
          ) systems
        );

      defaultModule =
        {
          app,
          args,
        }:
        let
          pkgs = args.pkgs;
          lib = args.lib;
          config = args.config;
          name = app.name;
          description = app.description or "";
          useNetwork = app.module.network or true;
          useStorage = app.module.storage or true;

          cfg = config.services.${name};
          system = pkgs.stdenv.hostPlatform.system;
          output = rustApp {
            inherit system pkgs app;
          };
        in
        {
          options = {
            services.${name} = {
              enable = lib.mkEnableOption "Enable ${name}.";

              package = lib.mkOption {
                type = lib.types.package;
                default = output.package;
                description = ''
                  ${name} equivalent executable.
                '';
              };
            };
          };

          config = lib.mkIf cfg.enable {
            users.groups.${name} = { };
            users.users.${name} = {
              isSystemUser = true;
              group = name;
            };

            systemd.services.${name} = {
              inherit description;
              wantedBy = if useNetwork then [ "network-online.target" ] else [ "multi-user.target" ];
              after = [ "network.target" ];
              serviceConfig = {
                ExecStart = "${lib.getExe cfg.package}";
                User = name;
                Group = name;
                Restart = "on-failure";
                WorkingDirectory = lib.mkIf useStorage "/var/lib/${name}";
                StateDirectory = lib.mkIf useStorage name;
              };
            };
          };
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

      outputBuilder =
        args: rawApp:
        let
          app = args.appProcess rawApp;
          name = app.name;
          default = app.default or true;
        in
        combine [
          (eachSystem (
            {
              system,
              pkgs,
            }:
            let
              output = args.appBuilder {
                inherit system pkgs app;
              };
            in
            {
              checks.${system}.${name} = output.check;

              packages.${system} = {
                ${name} = output.package;
              }
              // (if default then { default = output.package; } else { });

              devShells.${system} = {
                ${name} = output.devShell;
              }
              // (if default then { default = output.devShell; } else { });
            }
          ))
          (
            let
              enableModule = app.module.enable or true;
              module = { pkgs, ... }@args: defaultModule { inherit app args; };
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
        }:
        let
          name = app.name;
          implementation = app.implementation or "crate2nix";
          getArgs = app.getArgs or ({ pkgs }: { });
          args = getArgs { inherit pkgs; };
          src = app.src or args.src;
          extraCheckArgs = args.extraCheckArgs or args.extraArgs or { };
          extraPackageArgs = args.extraPackageArgs or args.extraArgs or { };
          extraDevShellArgs = args.extraDevShellArgs or args.extraArgs or { };
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
              check = build.override (
                {
                  runTests = true;
                }
                // extraCheckArgs

              );

              package = build.override extraPackageArgs;
            }
          else if implementation == "naersk" then
            let
              naersk' = pkgs.callPackage inputs.naersk { };
              build = (
                extraArgs:
                naersk'.buildPackage (
                  {
                    inherit name src;
                  }
                  // extraArgs
                )
              );
            in
            {
              check = build ({ mode = "test"; } // extraCheckArgs);

              package = build extraPackageArgs;
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          devShell = pkgs.mkShell (
            {
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
            }
            // extraDevShellArgs
          );
        };

      pythonApp =
        {
          system,
          pkgs,
          app,
        }:
        let
          name = app.name;
          version = app.version;
          getArgs = app.getArgs or ({ pkgs }: { });
          args = getArgs { inherit pkgs; };
          src = app.src or args.src;
          type = app.type or (if builtins.pathExists (src + "/uv.lock") then "uv" else "");
          implementation = app.implementation or (if type == "uv" then "uv2nix" else "pyproject.nix");
          # extraCheckArgs = args.extraCheckArgs or args.extraArgs or { };
          extraPackageArgs = args.extraPackageArgs or args.extraArgs or { };
          extraDevShellArgs = args.extraDevShellArgs or args.extraArgs or { };
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
              extraRequirements = app.extraRequirements or [ ];
              python = pkgs.python3;
              baseProject = inputs.pyproject-nix.lib.project.${loader} ({
                projectRoot = src;
              });
              finalDependencies =
                (builtins.map (
                  requirement:
                  (inputs.pyproject-nix.lib.project.loadRequirementsTxt {
                    requirements = builtins.readFile (src + "/${requirement}");
                  }).dependencies.dependencies
                ) extraRequirements)
                ++ [ baseProject.dependencies.dependencies ];
              project = baseProject // {
                dependencies = baseProject.dependencies // {
                  dependencies = builtins.concatLists finalDependencies;
                };
              };
            in
            {
              # TODO check

              package = pkgs.python3Packages.buildPythonPackage (
                (inputs.pyproject-nix.lib.renderers.buildPythonPackage { inherit python project; })
                // {
                  inherit version;
                  pname = name;
                }
                // extraPackageArgs
              );
            }
          else if implementation == "uv2nix" then
            let
              workspace = inputs.uv2nix.lib.workspace.loadWorkspace ({ workspaceRoot = src; });
              overlay = workspace.mkPyprojectOverlay {
                sourcePreference = "wheel";
              };
              python = pkgs.python3;
              pythonSet =
                (pkgs.callPackage inputs.pyproject-nix.build.packages {
                  inherit python;
                }).overrideScope
                  (
                    pkgs.lib.composeManyExtensions [
                      inputs.pyproject-build-systems.overlays.wheel
                      overlay
                    ]
                  );
              venv = pythonSet.mkVirtualEnv "${name}-${version}-venv" workspace.deps.default;
            in
            {
              # TODO check

              package = (pkgs.callPackages inputs.pyproject-nix.build.util { }).mkApplication {
                inherit venv;
                package = pythonSet.${name};
              };
            }
          else
            builtins.throw "Unknown implementation ${implementation}"
        )
        // {
          devShell = pkgs.mkShell (
            {
              buildInputs =
                (defaultDevShellBuildInputs { inherit pkgs; })
                ++ [
                  pkgs.python

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
                    [ ]
                );
              shellHook = ''
                code .
              '';
            }
            // extraDevShellArgs
          );
        };
    in
    {
      combine = combine;

      language =
        let
          rust = outputBuilder {
            appBuilder = rustApp;
            appProcess =
              app:
              (
                if app ? src then
                  let
                    metadata = builtins.fromTOML (builtins.readFile (app.src + "/Cargo.toml"));
                  in
                  {
                    name = metadata.package.name;
                    version = metadata.package.version;
                  }
                else
                  {
                    name = "rust-app";
                    version = "1.0.0";
                  }
              )
              // app;
          };
          python = outputBuilder {
            appBuilder = pythonApp;
            appProcess =
              app:
              (
                if app ? src then
                  let
                    metadata = builtins.fromTOML (builtins.readFile (app.src + "/pyproject.toml"));
                  in
                  {
                    name = metadata.project.name;
                    version = metadata.project.version;
                  }
                else
                  {
                    name = "python-app";
                    version = "1.0.0";
                  }
              )
              // app;
          };
        in
        {
          inherit rust python;

          auto =
            app:
            if builtins.pathExists (app.src + "/Cargo.toml") then
              rust app
            else if builtins.pathExists (app.src + "/pyproject.toml") then
              python app
            else
              builtins.throw "Could not detect language";
        };

      templates = {
        rust = {
          path = ./templates/rust/hello-world;
        };
        uv = {
          path = ./templates/python/uv;
        };
        poetry = {
          path = ./templates/python/poetry;
        };
      };
    };
}
