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
      lib = inputs.nixpkgs.lib;
      systems = import inputs.systems;

      merge = import ./lib/merge.nix { inherit lib; };
      helpers = import ./lib/helpers.nix { inherit lib merge; };
      wrapPackage = import ./lib/wrap.nix { inherit lib; };
      mkApp = import ./lib/mk-app.nix {
        inherit lib helpers wrapPackage;
      };
      defaultModule = import ./lib/module.nix { inherit lib; };

      # The entry point of `nixosModules.<name>`. The package of the module is
      # built with the nixpkgs of this flake, not with the nixpkgs of the
      # consumer, so the module and the flake output always use the same
      # package.
      mkModule =
        { app, appBuilder }:
        # `utils` is a `_module.args` value. Module arguments from
        # `_module.args` are only added to the argument set of a module
        # function for the names it declares, so `utils` has to be listed
        # explicitly to be part of `nixArgs`.
        { pkgs, utils, ... }@nixArgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          flakePkgs = import inputs.nixpkgs ({ inherit system; } // (app.pkgsImport or { }));
          output = mkApp {
            inherit
              appBuilder
              app
              system
              ;
            pkgs = flakePkgs;
          };
        in
        defaultModule {
          inherit
            app
            nixArgs
            output
            ;
        };

      languages = {
        rust = import ./languages/rust.nix { inherit inputs lib helpers; };
        python = import ./languages/python.nix { inherit inputs lib helpers; };
        go = import ./languages/go.nix { inherit inputs lib helpers; };
        javascript = import ./languages/javascript.nix { inherit inputs lib helpers; };
      };

      # The same as `eachSystem`, but the result of every system is nested
      # under the name of the system.
      eachSystemBySystem =
        pkgsImport: f:
        lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import inputs.nixpkgs ({ inherit system; } // pkgsImport);
          }
        );

      # Build the outputs of an application for every system and merge them
      # recursively, so the packages of every system survive.
      eachSystem =
        pkgsImport: f:
        merge.combine (
          builtins.map (
            system:
            f {
              inherit system;
              pkgs = import inputs.nixpkgs ({ inherit system; } // pkgsImport);
            }
          ) systems
        );

      outputBuilder =
        {
          appBuilder,
          appProcess,
        }:
        rawApp:
        let
          app = appProcess rawApp;
          name = app.name;
          default = app.default or true;
          pkgsImport = app.pkgsImport or { };
          customOutputs = app.outputs or { };
        in
        merge.combine [
          (eachSystem pkgsImport (
            {
              system,
              pkgs,
            }:
            let
              output = mkApp {
                inherit
                  appBuilder
                  system
                  pkgs
                  app
                  ;
              };
              src = output.src;

              custom = lib.mapAttrs (
                key: builder:
                let
                  result = builder {
                    inherit
                      pkgs
                      system
                      app
                      src
                      ;
                    appArgs = output.appArgs;
                    package = output.package;
                    check = output.check or null;
                  };
                in
                # A derivation is a package, an attribute set with a
                # `check` and/or a `package` attribute defines both of
                # them separately.
                if merge.isDerivation result then
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
                (if output ? check && output.check != null then { ${name} = output.check; } else { })
                // lib.mapAttrs' (
                  key: value: lib.nameValuePair "${name}-${key}" value
                ) (output.checks or { })
                // lib.mapAttrs' (key: value: lib.nameValuePair "${name}-${key}" value.check) customChecks;

              packages.${system} =
                {
                  ${name} = output.package;
                }
                // lib.mapAttrs' (key: value: lib.nameValuePair "${name}-${key}" value.package) customPackages
                // (if default then { default = output.package; } else { });

              devShells.${system} =
                {
                  ${name} = output.devShell;
                }
                // (if default then { default = output.devShell; } else { });
            }
            // lib.optionalAttrs (default && output ? formatter) {
              formatter.${system} = output.formatter;
            }
          ))
          (
            let
              enableModule = if app.module or { } ? enable then app.module.enable else true;
              module = mkModule { inherit app appBuilder; };
            in
            if enableModule then
              {
                nixosModules =
                  {
                    ${name} = module;
                  }
                  // (if default then { default = module; } else { });
              }
            else
              { }
          )
        ];

      builders = {
        rust = outputBuilder languages.rust;
        python = outputBuilder languages.python;
        go = outputBuilder languages.go;
        javascript = outputBuilder languages.javascript;

        auto =
          app:
          if builtins.pathExists (app.src + "/Cargo.toml") then
            builders.rust app
          else if builtins.pathExists (app.src + "/pyproject.toml") then
            builders.python app
          else if builtins.pathExists (app.src + "/go.mod") then
            builders.go app
          else if builtins.pathExists (app.src + "/package.json") then
            builders.javascript app
          else
            builtins.throw "Could not detect language";
      };
    in
    {
      lib = {
        inherit (merge)
          mergeableKeys
          isDerivation
          mergeValues
          resolveOverrides
          normalizeAppArgs
          combine
          ;
        inherit
          builders
          wrapPackage
          mkApp
          defaultModule
          ;
      };

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

          # The package without the environment/rpath wrapper.
          unwrapped = package: package.passthru.unwrapped or package;

          # The app with an override tree that covers every layer.
          overridden = builders.rust {
            src = ./tests/rust;
            implementation = "buildRustPackage";
            getArgs =
              { pkgs, ... }:
              {
                override = {
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
          };

          package = overridden.packages.${system}.test-app;
          check = overridden.checks.${system}.test-app;
          shell = overridden.devShells.${system}.test-app;

          # The app with custom outputs.
          withOutputs = builders.rust {
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
              builders.rust {
                src = ./tests/rust;
                implementation = "crate2nix";
                getArgs =
                  { pkgs, ... }:
                  {
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
                  };
              }
            else
              null;

          # The Python app of the `pyproject.nix` implementation. The
          # check scope builds the package with its tests.
          python = builders.python {
            src = ./tests/python;
            implementation = "pyproject.nix";
          };

          # The JavaScript app. The check scope runs the `test` script of
          # the package.
          javascript = builders.javascript {
            src = ./tests/javascript;
          };

          # The packages of every system have to be present, not only the
          # packages of the last system.
          multiSystem = builders.rust {
            src = ./tests/rust;
            implementation = "buildRustPackage";
          };

          # The default Rust implementation. It exposes the clippy, fmt and
          # nextest checks in addition to the package.
          crane = builders.rust {
            src = ./tests/rust;
          };

          formatter = multiSystem.formatter.${system};

          unit = import ./tests/unit/default.nix {
            inherit
              lib
              helpers
              merge
              mkApp
              mkModule
              inputs
              pkgs
              system
              ;
          };

          vm =
            if pkgs.stdenv.hostPlatform.isLinux then
              import ./tests/vm/default.nix {
                inherit
                  pkgs
                  lib
                  mkModule
                  ;
              }
            else
              null;
        in
        assertions (
          {
            # The generic argument of `common.common` is applied to every
            # scope.
            "generic-argument-common" =
              inputNames (unwrapped package) == [
                "coreutils"
                "hello"
                "cowsay"
              ];

            # The generic argument of the package scope is not applied to the
            # check scope.
            "generic-argument-scope" = inputNames (unwrapped check) == [ "hello" ];

            # The argument of the build step is applied to every scope.
            "step-argument-common" =
              (unwrapped package).drvAttrs.cargoBuildFlags == [ "--locked" ]
              && (unwrapped check).drvAttrs.cargoBuildFlags == [ "--locked" ];

            # The argument of the build step of the check scope is only
            # applied to the check scope.
            "step-argument-scope" =
              (unwrapped check).drvAttrs.doCheck == true
              && (unwrapped package).drvAttrs.doCheck == false;

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
              withOutputs.packages.${system}.test-app-extra-package.drvAttrs.package.drvPath
              == withOutputs.packages.${system}.test-app.drvPath;

            # The check scope of the Python implementation runs the tests
            # of the package, the package scope does not.
            "python-check-argument" =
              (unwrapped python.checks.${system}.test-app).drvAttrs.doInstallCheck == true
              && (unwrapped python.packages.${system}.test-app).drvAttrs.doInstallCheck == false;

            # The check scope of the Python implementation adds the pytest
            # hook to the build, the package scope does not.
            "python-check-inputs" =
              builtins.elem "pytest-check-hook" (
                map (input: input.name or input.pname or "?") (
                  unwrapped python.checks.${system}.test-app
                ).drvAttrs.nativeBuildInputs
              )
              && !(builtins.elem "pytest-check-hook" (
                map (input: input.name or input.pname or "?") (
                  unwrapped python.packages.${system}.test-app
                ).drvAttrs.nativeBuildInputs
              ));

            # The check scope of the JavaScript implementation runs the
            # `test` script of the package, the package scope does not.
            "javascript-check-argument" =
              (unwrapped javascript.checks.${system}.test-app).drvAttrs.doCheck == true
              && (unwrapped javascript.packages.${system}.test-app).drvAttrs.doCheck == false;

            # The JavaScript implementation has no built-in check phase, the
            # check scope adds one.
            "javascript-check-phase" =
              (unwrapped javascript.checks.${system}.test-app).drvAttrs ? checkPhase
              && !((unwrapped javascript.packages.${system}.test-app).drvAttrs ? checkPhase);

            # All systems are present, not only the last one. `attrNames` is
            # sorted, so compare against the sorted system list.
            "multi-system" = builtins.attrNames multiSystem.packages == lib.sort builtins.lessThan systems;

            # `formatter.<system>` is a single derivation for `nix fmt`.
            "formatter-is-derivation" = merge.isDerivation formatter;

            # The default Rust implementation exposes the tests, clippy and
            # formatting as checks.
            "crane-check" = merge.isDerivation crane.checks.${system}.test-app;
            "crane-clippy" = merge.isDerivation crane.checks.${system}.test-app-clippy;
            "crane-fmt" = merge.isDerivation crane.checks.${system}.test-app-fmt;
          }
          // (
            if crate2nix == null then
              { }
            else
              {
                # The arguments of the build step of the crate2nix
                # implementation are applied to the crate.
                "crate2nix-step-argument" =
                  (unwrapped crate2nix.packages.${system}.test-app).drvAttrs.crateFeatures == [ "default" ];

                # The generic arguments are applied to the crate of the
                # application.
                "crate2nix-generic-argument" =
                  inputNames (unwrapped crate2nix.packages.${system}.test-app) == [
                    "hello"
                    "coreutils"
                  ];

                # The arguments of the tests are applied to the crate of the
                # tests.
                "crate2nix-test-argument" =
                  inputNames (unwrapped crate2nix.checks.${system}.test-app).passthru.test == [ "coreutils" ];
              }
          )
        )
        // { inherit unit; }
        // lib.optionalAttrs (vm != null) vm
        # Actually run the checks of the default Rust implementation instead
        # of only asserting that they exist.
        // crane.checks.${system}
      );
    };
}
