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
      cacheDirectory = framework == "nextjs" || framework == "nextjs-standalone";
      # The base directory of the runtime cache. When it is not set, the
      # script uses `$CACHE_DIRECTORY`, which systemd sets for the
      # `CacheDirectory = name` of the module. It resolves to
      # `/var/cache/<name>` for system units and `%C/<name>` for user units.
      cacheDir = appArgs.cacheDir or null;

      # Next.js writes to `.next/cache`, but the store is read-only. Run the
      # app from a writable directory below the cache directory and mirror
      # the read-only files as symlinks. The cache directory is created by
      # systemd for both system and user services, so the same script works
      # for both.
      nextStart =
        args: { command }:
        ''
          export PATH="${pkgs.coreutils}/bin:$PATH"

          cache_base=${if cacheDir != null then lib.escapeShellArg cacheDir else ''"$CACHE_DIRECTORY"''}
          if [ -z "$cache_base" ]; then
            cache_base="$XDG_CACHE_HOME"
            if [ -z "$cache_base" ]; then
              cache_base="$HOME/.cache"
            fi
            cache_base="$cache_base/${name}"
          fi

          run_dir="$cache_base/run"
          mkdir -p "$run_dir/.next"

          for entry in "${args.dir}"/* "${args.dir}"/.[!.]*; do
            [ -e "$entry" ] || continue
            base="$(basename "$entry")"
            [ "$base" = ".next" ] && continue
            ln -sfn "$entry" "$run_dir/$base"
          done

          for entry in "${args.dir}"/.next/* "${args.dir}"/.next/.[!.]*; do
            [ -e "$entry" ] || continue
            base="$(basename "$entry")"
            [ "$base" = "cache" ] && continue
            ln -sfn "$entry" "$run_dir/.next/$base"
          done

          mkdir -p "$run_dir/.next/cache"
          cd "$run_dir"
          ${command}
        '';

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
              execute =
                args:
                nextStart args {
                  command = "${args.npm} run start";
                };
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
              execute =
                args:
                nextStart args {
                  command = "${args.node} \"$run_dir/server.js\"";
                };
              commands = ''
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

      installPhaseScript = ''
        runHook preInstall

        mkdir -p $out/{share,bin}
        ${builtins.concatStringsSep "\n" (
          builtins.map (toCopy: "cp --parents -r ${toCopy} $out/share") installArgs.copy or [ ]
        )}
        cat > $out/bin/${name} << 'EOF'
        #!${pkgs.lib.getExe pkgs.bash}
        # The script body is not expanded by the install phase, so define
        # `out` for `execute` overrides that still refer to it.
        out=${builtins.placeholder "out"}
        ${(installArgs.execute or (args: "")) {
          node = pkgs.lib.getExe pkgs.nodejs;
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

      commonDefaults = scope: {
        pname = name;
        inherit version src;
        meta = {
          mainProgram = name;
        };
        doCheck = scope == "check" && packageJson.scripts ? test;
        installPhase = installPhaseScript;
      };

      checkPhase = ''
        runHook preCheck
        ${testCommand}
        runHook postCheck
      '';

      npmBuild =
        scope:
        let
          resolved = resolve scope {
            buildNpmPackage =
              commonDefaults scope
              // {
                npmDeps = pkgs.importNpmLock {
                  pname = name;
                  inherit version;
                  npmRoot = src;
                };
                npmConfigHook = pkgs.importNpmLock.npmConfigHook;
              }
              // (
                if scope == "check" && packageJson.scripts ? test then
                  { inherit checkPhase; }
                else
                  { }
              );
          };
        in
        pkgs.buildNpmPackage (
          mergeValues {
            prev = resolved.stepArgs.buildNpmPackage;
            next = resolved.genericArgs;
            extendLists = true;
          }
        );

      pnpmBuild =
        scope:
        let
          resolved = resolve scope {
            buildNpmPackage =
              commonDefaults scope
              // {
                pnpmDeps = pkgs.fetchPnpmDeps {
                  pname = name;
                  inherit version src;
                  hash = appArgs.pnpmDepsHash or pkgs.lib.fakeHash;
                  fetcherVersion = if lib.versionAtLeast pkgs.pnpm.version "11" then 4 else 3;
                };
                nativeBuildInputs = [
                  pkgs.nodejs
                  pkgs.pnpm
                  pkgs.pnpmConfigHook
                ];
                buildPhase = ''
                  runHook preBuild
                  ${lib.optionalString (packageJson.scripts ? build) "pnpm run build"}
                  runHook postBuild
                '';
              }
              // (
                if scope == "check" && packageJson.scripts ? test then
                  { inherit checkPhase; }
                else
                  { }
              );
          };
        in
        pkgs.stdenv.mkDerivation (
          mergeValues {
            prev = resolved.stepArgs.buildNpmPackage;
            next = resolved.genericArgs;
            extendLists = true;
          }
        );

      yarnBuild =
        scope:
        let
          resolved = resolve scope {
            buildNpmPackage =
              commonDefaults scope
              // {
                offlineCache = pkgs.fetchYarnDeps {
                  yarnLock = src + "/yarn.lock";
                  hash = appArgs.yarnDepsHash or pkgs.lib.fakeHash;
                };
                nativeBuildInputs = [
                  pkgs.nodejs
                  pkgs.yarn
                  pkgs.yarnConfigHook
                ];
                buildPhase = ''
                  runHook preBuild
                  ${lib.optionalString (packageJson.scripts ? build) "yarn run build"}
                  runHook postBuild
                '';
              }
              // (
                if scope == "check" && packageJson.scripts ? test then
                  { inherit checkPhase; }
                else
                  { }
              );
          };
        in
        pkgs.stdenv.mkDerivation (
          mergeValues {
            prev = resolved.stepArgs.buildNpmPackage;
            next = resolved.genericArgs;
            extendLists = true;
          }
        );

      buildFor =
        scope:
        if type == "npm" then
          npmBuild scope
        else if type == "pnpm" then
          pnpmBuild scope
        else if type == "yarn" then
          yarnBuild scope
        else if type == "bun" then
          builtins.throw ''
            The bun package manager is not supported by the JavaScript builder.
            Use npm, pnpm, or yarn instead.
          ''
        else
          builtins.throw ''
            Could not detect the package manager of ${name}.
            Add a package-lock.json, pnpm-lock.yaml, or yarn.lock to the source,
            or set `type = "npm" | "pnpm" | "yarn"` on the application.
          '';

      devShell =
        let
          resolved = resolve "devshell" {
            shell = {
              buildInputs =
                (defaultDevShellBuildInputs { inherit pkgs; })
                ++ [ pkgs.python ]
                ++ (
                  if type == "npm" then
                    [ pkgs.nodejs ]
                  else if type == "yarn" then
                    [
                      pkgs.nodejs
                      pkgs.yarn
                    ]
                  else if type == "pnpm" then
                    [
                      pkgs.nodejs
                      pkgs.pnpm
                    ]
                  else if type == "bun" then
                    [ pkgs.bun ]
                  else
                    [ ]
                );
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
      if implementation == "buildNpmPackage" then
        {
          check = buildFor "check";
          package = buildFor "package";
          extra = {
            inherit
              appArgs
              type
              framework
              cacheDirectory
              ;
          };
        }
      else
        builtins.throw "Unknown implementation ${implementation}"
    )
    // {
      inherit
        devShell
        cacheDirectory
        ;
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
}
