{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.auto {
      name = "hello-world";
      version = "1.0.0";
      src = ./.;
      getArgs =
        { ... }:
        {
          extraPackageArgs = {
            vendorHash = null;
          };
        };
    };
}
