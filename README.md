# Xnode Builders

Application builders to run your app seamlessly on XnodeOS.

## Getting Started

## New Project

Pick a template:  
`nix flake init -t github:Openmesh-Network/xnode-builders#rust`  
`nix flake init -t github:Openmesh-Network/xnode-builders#poetry`  
`nix flake init -t github:Openmesh-Network/xnode-builders#uv`

### Existing Project

Create a file called flake.nix at the root of your project repository with the following content.

```nix
{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.auto {
      src = ./.;
    };
}
```

In most cases, that's all you have to do! You can now use the power of nix to run your app on any platform.

## Manual Definition

### Rust

```nix
{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.rust {
      src = ./.;
    };
}
```

### Python

```nix
{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.python {
      src = ./.;
    };
}
```

## XnodeOS Application Flake

Replace all instances of "hello-world" with your application name.
Update the first input to point to your project (replace Openmesh-Network/xnode-builders with your organization and repository name, omit ?dir= if flake.nix is located at the project root)

```nix
{
  inputs = {
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
```
