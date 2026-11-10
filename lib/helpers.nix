{ lib, merge }:
let
  defaultDevShellBuildInputs = { pkgs }: [ pkgs.git ];

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
in
{
  inherit (merge)
    mergeableKeys
    isDerivation
    mergeValues
    implementationSteps
    implementationSpecialArgs
    commonSteps
    scopeSteps
    resolveOverrides
    normalizeAppArgs
    combine
    ;
  inherit defaultDevShellBuildInputs mkUpdate;
}
