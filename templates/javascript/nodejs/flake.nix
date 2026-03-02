{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.auto {
      src = ./.;
      getArgs =
        { pkgs, ... }:
        {
          # This depends on your build output (npm run build)
          frameworkArgs = {
            copy = [ "dist" ];
            execute = args: "${args.node} ${args.dir}/dist/index.js";
          };
        };
    };
}
