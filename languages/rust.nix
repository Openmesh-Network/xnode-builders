{ inputs, lib, helpers }:
let
  inherit (helpers)
    mergeValues
    resolveOverrides
    defaultDevShellBuildInputs
    mkUpdate
    ;
in
{
  appBuilder =
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
      implementation = app.implementation or "crane";
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
          specialArgs = helpers.implementationSpecialArgs.${implementation} or { };
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

      # Build the dependencies once from arguments that do not depend on the
      # scope. Otherwise the package and the check scope build their own
      # cargo artifacts, even though they use the same dependencies.
      craneArtifacts =
        let
          resolved = resolve "package" {
            buildPackage = {
              src = craneLib.cleanCargoSource src;
              strictDeps = true;
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
        in
        packageArgs.cargoArtifacts or (craneLib.buildDepsOnly depsArgs);

      craneBuild =
        scope:
        let
          resolved = resolve scope {
            buildPackage = {
              src = craneLib.cleanCargoSource src;
              strictDeps = true;
            };
            buildDepsOnly = { };
            cargoClippy = { };
            cargoFmt = { };
            cargoNextest = { };
          };
          packageArgs = mergeValues {
            prev = resolved.stepArgs.buildPackage;
            next = resolved.genericArgs;
            extendLists = true;
          };
          mergeStep =
            step:
            mergeValues {
              prev = packageArgs;
              next = resolved.stepArgs.${step};
              extendLists = true;
            };
          withArtifacts = attrs: attrs // { cargoArtifacts = attrs.cargoArtifacts or craneArtifacts; };
          fmtArgs = mergeValues {
            prev = {
              src = craneLib.cleanCargoSource src;
            };
            next = resolved.stepArgs.cargoFmt;
            extendLists = true;
          };
        in
        {
          args = withArtifacts packageArgs;
          clippy = craneLib.cargoClippy (withArtifacts (mergeStep "cargoClippy"));
          fmt = craneLib.cargoFmt fmtArgs;
          nextest = craneLib.cargoNextest (withArtifacts (mergeStep "cargoNextest"));
          cargoArtifacts = (withArtifacts packageArgs).cargoArtifacts;
        };

      buildRustPackageBuild =
        scope:
        let
          rustPlatform = appArgs.rustPlatform or pkgs.rustPlatform;
          resolved = resolve scope {
            buildPackage =
              {
                inherit name version src;
                doCheck = scope == "check";
              }
              // lib.optionalAttrs (src != null && builtins.pathExists (src + "/Cargo.lock")) {
                cargoLock.lockFile = src + "/Cargo.lock";
              };
          };
        in
        rustPlatform.buildRustPackage (
          mergeValues {
            prev = resolved.stepArgs.buildPackage;
            next = resolved.genericArgs;
            extendLists = true;
          }
        );

      devShell =
        let
          resolved = resolve "devshell" {
            shell = {
              buildInputs = (defaultDevShellBuildInputs { inherit pkgs; }) ++ [
                pkgs.cargo
                pkgs.rustc
                pkgs.rustfmt
                pkgs.clippy
                pkgs.rust-analyzer
              ];
              RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
            };
          };
        in
        pkgs.mkShell (
          mergeValues {
            prev = resolved.stepArgs.shell;
            next = resolved.genericArgs;
            extendLists = true;
          }
        );
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
          packageBuild = craneBuild "package";
          checkBuild = craneBuild "check";
        in
        {
          # Run the tests with nextest instead of rebuilding the package with
          # `doCheck`, and expose clippy and formatting as separate checks.
          check = checkBuild.nextest;
          package = craneLib.buildPackage packageBuild.args;
          checks = {
            clippy = checkBuild.clippy;
            fmt = checkBuild.fmt;
          };
          extra = {
            inherit appArgs craneLib;
            cargoArtifacts = packageBuild.cargoArtifacts;
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
      formatter = pkgs.writeShellApplication {
        name = "${name}-formatter";
        runtimeInputs = [ pkgs.rustfmt pkgs.cargo ];
        text = ''
          if [ "$#" -gt 0 ] && [ -d "$1" ]; then
            cd "$1"
          fi
          cargo fmt
        '';
      };
    };

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
}
