{
  inputs = {
    # Replace first input url with your github repo
    hello-world.url = "github:Openmesh-Network/xnode-builders?dir=templates/rust/hello-world";
    nixpkgs.follows = "hello-world/xnode-builders/nixpkgs";
    xnodeos = {
      url = "github:Openmesh-Network/xnodeos/v1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: {
    nixosConfigurations.container = inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
      };
      modules = [
        inputs.xnodeos.nixosModules.container
        {
          services.xnode-container.xnode-config = ./xnode-config;
        }
        inputs.hello-world.nixosModules.default
        (
          { pkgs, ... }@args:
          {
            services.hello-world.enable = true;
          }
        )
      ];
    };
  };
}
