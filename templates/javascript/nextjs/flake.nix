{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.auto {
      src = ./.;
      # Recommended to reduce final package size (requires changing next.config.ts)
      # framework = "nextjs-standalone";
    };
}
