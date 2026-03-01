{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  nixConfig = {
    extra-substituters = [
      "https://openmesh.cachix.org"
    ];
    extra-trusted-public-keys = [
      "openmesh.cachix.org-1:du4NDeMWxcX8T5GddfuD0s/Tosl3+6b+T2+CLKHgXvQ="
    ];
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.rust {
      name = "xnode-manager";
      getArgs =
        { pkgs, ... }:
        {
          src =
            pkgs.fetchFromGitHub {
              owner = "Openmesh-Network";
              repo = "xnode-manager";
              tag = "v1.0.2";
              hash = "sha256-svxx9B3O6b6ILq0TrtabSfSgR6vYGIq1pFNaCm+sA10=";
            }
            + "/rust-app";

          extraArgs = {
            crateOverrides = pkgs.defaultCrateOverrides // {
              xnode-manager = attrs: {
                buildInputs = [ pkgs.acl ];
              };
            };
          };
        };
    };
}
