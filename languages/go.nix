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
      implementation = app.implementation or "buildGoModule";
      override = appArgs.override or { };

      # `buildGoModule` names the binary after the main package, which is the
      # last component of the module path. Do not assume that it matches the
      # application name.
      goMod = if src != null && builtins.pathExists (src + "/go.mod") then builtins.readFile (src + "/go.mod") else "";
      modulePath =
        let
          moduleLines = builtins.filter (line: lib.hasPrefix "module " line) (lib.splitString "\n" goMod);
        in
        if moduleLines == [ ] then "" else lib.removePrefix "module " (lib.trim (builtins.head moduleLines));
      mainProgram = appArgs.mainProgram or (if modulePath == "" then name else builtins.baseNameOf modulePath);

      vendorHash =
        appArgs.vendorHash or (
          if src != null && builtins.pathExists (src + "/vendor") then
            null
          else
            pkgs.lib.fakeHash
        );

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

      goBuild =
        scope:
        let
          resolved = resolve scope {
            buildGoModule = {
              pname = name;
              inherit version src vendorHash;
              doCheck = scope == "check";
              meta = {
                inherit mainProgram;
              };
            };
          };
        in
        pkgs.buildGoModule (
          mergeValues {
            prev = resolved.stepArgs.buildGoModule;
            next = resolved.genericArgs;
            extendLists = true;
          }
        );

      devShell =
        let
          resolved = resolve "devshell" {
            shell = {
              buildInputs = (defaultDevShellBuildInputs { inherit pkgs; }) ++ [
                pkgs.go
              ];
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
      if implementation == "buildGoModule" then
        {
          check = goBuild "check";

          package = goBuild "package";
          extra = {
            inherit
              appArgs
              vendorHash
              mainProgram
              ;
          };
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
      formatter = pkgs.writeShellApplication {
        name = "${name}-formatter";
        runtimeInputs = [ pkgs.go ];
        text = ''
          if [ "$#" -gt 0 ] && [ -d "$1" ]; then
            cd "$1"
          fi
          gofmt -w .
        '';
      };
    };

  appProcess =
    app:
    {
      name = "go-app";
      version = "1.0.0";
    }
    // app;
}
