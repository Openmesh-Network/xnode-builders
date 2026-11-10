{ lib, helpers, wrapPackage }:
{
  appBuilder,
  system,
  pkgs,
  app,
  appArgs ? null,
}:
let
  rawArgs = if appArgs != null then appArgs else (app.getArgs or (_: { })) { inherit pkgs; };
  normalized = helpers.normalizeAppArgs {
    inherit pkgs app;
    appArgs = rawArgs;
  };
  output = appBuilder {
    inherit
      system
      pkgs
      app
      ;
    appArgs = normalized.appArgs;
  };
  passthru =
    (lib.optionalAttrs (output ? extra) output.extra)
    // (lib.optionalAttrs (output ? update) { inherit (output) update; });
  package = wrapPackage { inherit pkgs; } {
    package = output.package;
    env = normalized.env;
    rpath = normalized.rpath;
    passthru = passthru;
  };
in
output
// {
  inherit package;
  inherit (normalized)
    appArgs
    env
    rpath
    src
    override
    ;
}
