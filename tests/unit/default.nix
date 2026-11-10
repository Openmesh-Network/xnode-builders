{ lib, helpers, merge, mkApp, defaultModule, inputs, pkgs, system }:
let
  pureTests = {
    # `mergeValues` applies a function of an absent list argument to an
    # empty list instead of leaking the function into the result.
    testMergeValuesAbsentFunction = {
      expr = helpers.mergeValues {
        prev = { };
        next = {
          buildInputs = prev: prev ++ [ "hello" ];
        };
      };
      expected = {
        buildInputs = [ "hello" ];
      };
    };

    # A function of a list argument extends the previous value.
    testMergeValuesExtendsList = {
      expr = helpers.mergeValues {
        prev = {
          buildInputs = [ "a" ];
        };
        next = {
          buildInputs = prev: prev ++ [ "b" ];
        };
      };
      expected = {
        buildInputs = [
          "a"
          "b"
        ];
      };
    };

    # Two functions of the same list argument are composed.
    testMergeValuesComposesFunctions = {
      expr = helpers.mergeValues {
        prev = {
          buildInputs = prev: prev ++ [ "a" ];
        };
        next = {
          buildInputs = prev: prev ++ [ "b" ];
        };
      };
      expected = {
        buildInputs = [
          "a"
          "b"
        ];
      };
    };

    # Functions are only applied for the list arguments in
    # `mergeableKeys`. A function on any other argument is kept as-is.
    testMergeValuesNonMergeableFunction = {
      expr = builtins.isFunction (helpers.mergeValues {
        prev = { };
        next = {
          preBuild = previous: previous;
        };
      }).preBuild;
      expected = true;
    };

    # Attribute sets are merged recursively.
    testMergeValuesNested = {
      expr = helpers.mergeValues {
        prev = {
          a = {
            b = 1;
          };
        };
        next = {
          a = {
            c = 2;
          };
        };
      };
      expected = {
        a = {
          b = 1;
          c = 2;
        };
      };
    };

    # `extendLists` concatenates lists instead of overwriting them.
    testMergeValuesExtendLists = {
      expr = helpers.mergeValues {
        prev = {
          x = [ 1 ];
        };
        next = {
          x = [ 2 ];
        };
        extendLists = true;
      };
      expected = {
        x = [
          1
          2
        ];
      };
    };

    # `combine` is recursive, so the results of every system survive.
    testCombineRecursive = {
      expr = merge.combine [
        { packages.a = 1; }
        { packages.b = 2; }
      ];
      expected = {
        packages = {
          a = 1;
          b = 2;
        };
      };
    };

    # `combine` must not merge derivations attribute by attribute. The later
    # derivation replaces the earlier one instead of producing a hybrid.
    testCombineDerivation = {
      expr =
        (merge.combine [
          { packages.x.default = { drvPath = "/first"; outPath = "/first"; }; }
          { packages.x.default = { drvPath = "/second"; outPath = "/second"; }; }
        ]).packages.x.default.drvPath;
      expected = "/second";
    };

    # A top-level `override` on the application is intentionally ignored.
    testNormalizeAppArgsIgnoresAppOverride = {
      expr = (helpers.normalizeAppArgs {
        pkgs = { };
        app = {
          override = {
            package = { };
          };
        };
        appArgs = { };
      }).override;
      expected = { };
    };

    # `getArgs.override` is the supported way to override build arguments.
    testNormalizeAppArgsUsesGetArgsOverride = {
      expr = (helpers.normalizeAppArgs {
        pkgs = { };
        app = { };
        appArgs = {
          override = {
            package = { };
          };
        };
      }).override;
      expected = {
        package = { };
      };
    };

    # `src` on the application wins over `getArgs.src`.
    testNormalizeAppArgsSrcPrecedence = {
      expr = (helpers.normalizeAppArgs {
        pkgs = { };
        app = {
          src = "/app";
        };
        appArgs = {
          src = "/args";
        };
      }).src;
      expected = "/app";
    };

    # The override layers are applied from the least to the most specific
    # one, and generic list arguments are additive.
    testResolveOverridesLayers = {
      expr = (helpers.resolveOverrides {
        override = {
          common.common.buildInputs = [ "common" ];
          package.common.buildInputs = [ "package" ];
          package.buildRustPackage.buildPackage.cargoBuildFlags = [ "--locked" ];
        };
        scope = "package";
        implementation = "buildRustPackage";
        defaults = {
          buildPackage = { };
        };
        specialArgs = { };
      }).genericArgs.buildInputs;
      expected = [
        "common"
        "package"
      ];
    };

    testResolveOverridesStepArgs = {
      expr = (helpers.resolveOverrides {
        override = {
          package.buildRustPackage.buildPackage.cargoBuildFlags = [ "--locked" ];
        };
        scope = "package";
        implementation = "buildRustPackage";
        defaults = {
          buildPackage = { };
        };
        specialArgs = { };
      }).stepArgs.buildPackage.cargoBuildFlags;
      expected = [ "--locked" ];
    };

    # Special arguments are stored under their slot name, but belong to the
    # build step named in `specialArgs`. They have to be applied to that
    # step, otherwise they are silently dropped.
    testResolveOverridesCrate2nixFeatures = {
      expr = (helpers.resolveOverrides {
        override = {
          package.crate2nix.features = [ "default" ];
        };
        scope = "package";
        implementation = "crate2nix";
        defaults = {
          build = { };
        };
        specialArgs = {
          features = "build";
        };
      }).stepArgs.build.features;
      expected = [ "default" ];
    };

    testResolveOverridesUv2nixOverride = {
      expr = (helpers.resolveOverrides {
        override = {
          package.uv2nix.override = {
            foo = "bar";
          };
        };
        scope = "package";
        implementation = "uv2nix";
        defaults = {
          pythonSet = { };
          venv = { };
          application = { };
        };
        specialArgs = {
          override = "pythonSet";
        };
      }).stepArgs.pythonSet.override;
      expected = {
        foo = "bar";
      };
    };
  };

  fakeAppBuilder =
    { pkgs, ... }:
    {
      package = pkgs.writeShellScriptBin "xnode-test" ''
        exec ${pkgs.coreutils}/bin/sleep infinity
      '';
      devShell = pkgs.mkShell { };
      formatter = pkgs.writeShellScriptBin "xnode-test-formatter" "true";
      check = null;
    };

  fakeCacheAppBuilder =
    args:
    (fakeAppBuilder args)
    // {
      cacheDirectory = true;
    };

  fakeApp = {
    name = "xnode-test";
    version = "1.0.0";
    getArgs = _: { };
    module = { };
  };

  fakeUserApp = fakeApp // {
    module = {
      userService = true;
    };
  };

  evalApp =
    app: appBuilder: extraModules:
    lib.nixosSystem {
      inherit system;
      modules = [
        ({ config, utils, ... }: defaultModule {
          inherit app appBuilder;
          nixArgs = {
            inherit pkgs lib config utils;
          };
        })
        { services.xnode-test.enable = true; }
      ]
      ++ extraModules;
    };

  expectedPackage = (mkApp {
    appBuilder = fakeAppBuilder;
    inherit system pkgs;
    app = fakeApp;
  }).package;

  moduleTests = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
    let
      systemEval = evalApp fakeApp fakeAppBuilder [ ];
      userEval = evalApp fakeUserApp fakeAppBuilder [ ];
      cacheEval = evalApp fakeApp fakeCacheAppBuilder [ ];
      userCacheEval = evalApp fakeUserApp fakeCacheAppBuilder [ ];
      unhardenedEval = evalApp (fakeApp // { module = { harden = false; }; }) fakeAppBuilder [ ];
      argsEval = evalApp fakeApp fakeAppBuilder [
        {
          services.xnode-test.args = [
            "--foo"
            "a%b$c"
          ];
        }
      ];
    in
    {
      # The module uses the same wrapped package as the flake output.
      testModulePackageMatches = {
        expr = systemEval.config.services.xnode-test.package.drvPath == expectedPackage.drvPath;
        expected = true;
      };

      # Hardening is enabled by default.
      testModuleHardening = {
        expr = systemEval.config.systemd.services.xnode-test.serviceConfig.NoNewPrivileges;
        expected = true;
      };

      testModuleProtectSystem = {
        expr = systemEval.config.systemd.services.xnode-test.serviceConfig.ProtectSystem;
        expected = "strict";
      };

      testModuleProtectHome = {
        expr = systemEval.config.systemd.services.xnode-test.serviceConfig.ProtectHome;
        expected = true;
      };

      testModulePrivateTmp = {
        expr = systemEval.config.systemd.services.xnode-test.serviceConfig.PrivateTmp;
        expected = true;
      };

      # Hardening can be disabled with `module.harden = false`.
      testModuleHardeningDisabled = {
        expr = unhardenedEval.config.systemd.services.xnode-test.serviceConfig.NoNewPrivileges or false;
        expected = false;
      };

      # A system service creates its user and state directory.
      testModuleCreatesUser = {
        expr = systemEval.config.users.users ? xnode-test;
        expected = true;
      };

      testModuleWorkingDirectory = {
        expr = systemEval.config.systemd.services.xnode-test.serviceConfig.WorkingDirectory;
        expected = "/var/lib/xnode-test";
      };

      testModuleStateDirectory = {
        expr = systemEval.config.systemd.services.xnode-test.serviceConfig.StateDirectory;
        expected = "xnode-test";
      };

      # A user service does not create system users or set User/Group.
      testModuleUserServiceNoSystemUser = {
        expr = userEval.config.users.users ? xnode-test;
        expected = false;
      };

      testModuleUserServiceNoUser = {
        expr = userEval.config.systemd.user.services.xnode-test.serviceConfig ? User;
        expected = false;
      };

      testModuleUserServiceWorkingDirectory = {
        expr = userEval.config.systemd.user.services.xnode-test.serviceConfig.WorkingDirectory;
        expected = "%S/xnode-test";
      };

      # The state directory of a user service lives below the home
      # directory, so hardening must not protect the home directory.
      testModuleUserServiceProtectHome = {
        expr = userEval.config.systemd.user.services.xnode-test.serviceConfig.ProtectHome;
        expected = false;
      };

      # The builder can request a cache directory.
      testModuleCacheDirectory = {
        expr = cacheEval.config.systemd.services.xnode-test.serviceConfig.CacheDirectory;
        expected = "xnode-test";
      };

      # A user service uses the per-user cache directory. Systemd resolves
      # `CacheDirectory = name` to `%C/name` for user units.
      testModuleUserServiceCacheDirectory = {
        expr = userCacheEval.config.systemd.user.services.xnode-test.serviceConfig.CacheDirectory;
        expected = "xnode-test";
      };

      # `ExecStart` uses systemd escaping, not shell escaping.
      testModuleExecStartEscaping = {
        expr = lib.hasInfix "a%%b$$c" argsEval.config.systemd.services.xnode-test.serviceConfig.ExecStart;
        expected = true;
      };
    }
  );

  tests = pureTests // moduleTests;
  failures = lib.runTests tests;
in
if failures == [ ] then
  pkgs.runCommand "xnode-builders-unit-tests" { } ''
    touch $out
  ''
else
  lib.debug.throwTestFailures { inherit failures; }
