{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.auto {
      src = ./.;
      # Required for projects without vite config file
      # framework = "vite";
    };
}
