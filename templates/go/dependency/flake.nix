{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.auto {
      name = "dependency";
      version = "1.0.0";
      src = ./.;
      getArgs =
        { pkgs, ... }:
        {
          extraPackageArgs = {
            # Set to pkgs.lib.fakeHash and replace with the "got" from "hash mismatch in fixed-output derivation" after nix build / nix run
            vendorHash = "sha256-3rWfWAVcCVj1RN1gAlwRThZe9M2mBNTViE6z3OVPs90=";
          };
        };
    };
}
