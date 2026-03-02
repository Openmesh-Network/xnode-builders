{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.auto {
      src = ./.;
      framework = "astro-node";
      # Recommended to reduce final package size (requires changing astro.config.mjs)
      # framework = "astro-node-noext";
    };
}
