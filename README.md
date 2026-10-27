# Xnode Builders

Application builders to run your app seamlessly on XnodeOS.

## Getting Started

## New Project

Pick a template:  
`nix flake init -t github:Openmesh-Network/xnode-builders#rust`  
`nix flake init -t github:Openmesh-Network/xnode-builders#poetry`  
`nix flake init -t github:Openmesh-Network/xnode-builders#uv`  
`nix flake init -t github:Openmesh-Network/xnode-builders#go`  
`nix flake init -t github:Openmesh-Network/xnode-builders#nodejs`  
`nix flake init -t github:Openmesh-Network/xnode-builders#nextjs`  
`nix flake init -t github:Openmesh-Network/xnode-builders#vite`  
`nix flake init -t github:Openmesh-Network/xnode-builders#astro`  
`nix flake init -t github:Openmesh-Network/xnode-builders#react`

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
In case you are experiencing issues, check the flake.nix of the template that is most identical to your project (in terms of tech stack) if any additional configuration is required.

## Configuration

The application is described by an attribute set. The most important attributes are:

| Attribute      | Description                                                                              |
| -------------- | ---------------------------------------------------------------------------------------- |
| `src`          | The sources of the application, usually `./.`.                                            |
| `name`         | The name of the application, read from the manifest of the language if it is not given.   |
| `version`      | The version of the application, read from the manifest of the language if it is not given.|
| `implementation` | The builder that is used to build the application, see below.                           |
| `override`     | The overrides of the build arguments, see [Overriding build arguments](#overriding-build-arguments). |
| `outputs`      | Additional checks and packages, see [Custom outputs](#custom-outputs).                   |
| `getArgs`      | Language specific arguments, see [Language specific arguments](#language-specific-arguments). |
| `update`       | Update script exposed as `packages.<system>.<name>-update`. See [Updating dependencies](#updating-dependencies). |

The `implementation` selects the builder of the language of the application:

| Language    | Implementations                                     |
| ----------- | --------------------------------------------------- |
| Rust        | `crate2nix` (default), `naersk`, `crane`, `buildRustPackage` |
| Python      | `pyproject.nix` (default), `uv2nix`                 |
| Go          | `buildGoModule` (default)                           |
| JavaScript  | `buildNpmPackage` (default)                         |

### Overriding build arguments

Every argument of every build step can be customized with

```
override.<scope>.<implementation>.<slot>
```

#### Scopes

The `scope` defines which build the override is applied to:

| Scope      | Description                                            |
| ---------- | ------------------------------------------------------ |
| `check`    | The build of the tests of the application.             |
| `package`  | The build of the application itself.                   |
| `devshell` | The development shell of the application.              |
| `common`   | Applies to all of the scopes above.                    |

Every implementation has a `check` scope. The Rust and the Go builders run
their native test phase, the Python builder runs `pytest` of the package (the
`check` scope adds the `pytestCheckHook` and enables the install check) and the
JavaScript builder runs the `test` script of the `package.json` if the package
has one. Additional checks can be added with
[custom outputs](#custom-outputs).

#### Implementations

The `implementation` defines which builder the override is applied to:

| Implementation             | Description                                        |
| -------------------------- | -------------------------------------------------- |
| `crate2nix`, `naersk`, `crane`, `buildRustPackage` | The Rust builders.                    |
| `pyproject.nix`, `uv2nix`  | The Python builders.                                |
| `buildGoModule`            | The Go builder.                                     |
| `buildNpmPackage`          | The JavaScript builder.                             |
| `common`                   | Applies to all of the implementations above.        |

#### Slots

The `slot` is either

- the name of a build step of the implementation, in which case its value is an
  attribute set of arguments for that step, or
- a generic build argument, in which case its value is applied to the build of
  the implementation, wherever it fits best.

The build steps depend on the implementation:

| Implementation  | Build steps                             |
| --------------- | --------------------------------------- |
| `crate2nix`     | `build`                                 |
| `naersk`        | `buildPackage`                          |
| `crane`         | `buildPackage`, `buildDepsOnly`         |
| `buildRustPackage` | `buildPackage`                       |
| `pyproject.nix` | `buildPythonPackage`                    |
| `uv2nix`        | `pythonSet`, `venv`, `application`      |
| `buildGoModule` | `buildGoModule`                         |
| `buildNpmPackage` | `buildNpmPackage`                     |
| every one       | `shell` (the development shell)         |

Generic build arguments are for example `buildInputs`, `nativeBuildInputs`,
`checkInputs`, `testInputs`, `propagatedBuildInputs`, `patches`, `makeFlags`,
`configureFlags`, `buildFlags`, `checkFlags`, `installFlags`, `env` and `meta`.

#### Layers

The layers are applied from the least to the most specific one, every layer
overwrites the previous one:

1. the defaults of the implementation
2. `override.common.common`
3. `override.common.<implementation>`
4. `override.<scope>.common`
5. `override.<scope>.<implementation>`

#### Step arguments and generic arguments

The arguments of a build step replace the defaults of that step, attribute sets
are merged recursively:

```nix
override.package.buildRustPackage.buildPackage.buildInputs = [ pkgs.hello ];
```

The generic arguments are applied to the build of the implementation, wherever
it fits best. They are additive, their lists are appended to the lists of the
build instead of replacing them:

```nix
override.package.common.buildInputs = [ pkgs.hello ];
```

An argument should either be set as a step argument or as a generic argument,
not as both. If it is set as both, the generic argument wins.

#### Extending lists

The values of the following arguments can be functions of their previous value,
which makes it possible to extend a list without losing its defaults:

`buildInputs`, `buildInputs64`, `checkInputs`, `nativeBuildInputs`,
`nativeCheckInputs`, `propagatedBuildInputs`, `propagatedNativeBuildInputs`,
`testInputs`, `patches`, `makeFlags`, `configureFlags`, `buildFlags`,
`checkFlags`, `installFlags`.

```nix
override.package.common.buildInputs = prev: prev ++ [ pkgs.hello ];
```

If the argument does not exist yet, the previous value is an empty list.

#### Implementation specific arguments

Some arguments are handled by the implementation itself and are therefore
applied to a build step instead of being applied generically:

| Implementation | Argument                                                       | Build step |
| -------------- | -------------------------------------------------------------- | ---------- |
| `crate2nix`    | `features`, `crateOverrides`, `runTests`, `testCrateFlags`, `testInputs`, `testPreRun`, `testPostRun` | `build` |
| `uv2nix`       | `override`                                                     | `pythonSet` |

The generic arguments of `crate2nix` are applied to the override of the crate
of the application, the override of the crate is applied first and the generic
arguments are merged on top of it. The arguments of the build step of
`crate2nix` that the build step does not accept are applied to the crate of
the application as well. The generic arguments of `uv2nix` are applied to the
Python package of the application.

#### Example

```nix
{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.rust {
      name = "my-app";
      src = ./.;
      override = {
        # Applies to every scope and every implementation.
        common.common.buildInputs = [ pkgs.hello ];

        # Applies to every scope of the crate2nix implementation.
        common.crate2nix.build.runTests = true;

        # Applies to the package scope of every implementation.
        package.common.buildInputs = prev: prev ++ [ pkgs.cowsay ];

        # Applies to the build step of the package scope.
        package.buildRustPackage.buildPackage.buildInputs = [ pkgs.coreutils ];

        # Applies to the tests of the crate2nix implementation.
        check.crate2nix.build.testInputs = [ pkgs.coreutils ];
      };
    };
}
```

The `override` attribute can also be a function of the packages, which is
useful when the overridden arguments depend on the platform:

```nix
override =
  { pkgs, ... }:
  {
    package.buildGoModule.vendorHash = pkgs.lib.fakeHash;
  };
```

### Updating dependencies

Every application builder exposes an update script that updates the
dependency lock files of the application and the inputs of the flake. It is
exposed as `packages.<system>.<name>-update`:

```sh
nix run .#<name>-update
```

The script runs the language-specific update command followed by `nix flake
update`. For Rust it runs `cargo update`, for Go it runs `go get -u ./...` and
`go mod tidy`, for Python it runs `uv lock --upgrade` (uv) or `poetry update`
(poetry), and for JavaScript it runs `npm update`, `yarn upgrade`, `pnpm
update`, or `bun update` depending on the package manager. If the language
builder cannot update the dependencies (e.g. a Python project without a
supported lock file), only `nix flake update` is run.

The script can also be run from another directory by passing it as the first
argument.

### Custom outputs

Additional checks and packages can be added with the `outputs` attribute. Every
entry is a function that receives the arguments of the application and returns
either a derivation or an attribute set with a `check` and/or a `package`
attribute:

| Argument   | Description                                                       |
| ---------- | ----------------------------------------------------------------- |
| `pkgs`     | The packages of the system of the application.                    |
| `system`   | The system of the application.                                     |
| `app`      | The attributes of the application.                                |
| `appArgs`  | The language specific arguments of the application.               |
| `src`      | The sources of the application.                                   |
| `package`  | The package of the application.                                   |
| `check`    | The check of the application, `null` if it does not have one.      |

A derivation is added as a package, an attribute set is split into a check and
a package. They are exposed as `checks.<system>.<name>-<output>` and
`packages.<system>.<name>-<output>`:

```nix
{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.rust {
      name = "my-app";
      src = ./.;

      outputs = {
        # A check that runs the tests of the application.
        integration-test =
          { pkgs, package, ... }:
          pkgs.runCommand "my-app-integration-test" { inherit package; } ''
            ${package}/bin/my-app --version
            touch $out
          '';

        # A package that is built from the sources of the application.
        docs =
          { pkgs, src, ... }:
          pkgs.runCommand "my-app-docs" { inherit src; } ''
            cp -r ${src} $out
          '';

        # A check and a package at the same time.
        both =
          { pkgs, ... }:
          {
            check = pkgs.runCommand "my-app-both-check" { } "touch $out";
            package = pkgs.runCommand "my-app-both-package" { } "touch $out";
          };
      };
    };
}
```

### Language specific arguments

The `getArgs` attribute is a function of the packages that returns the
arguments of the language of the application:

| Language   | Arguments                                                                        |
| ---------- | -------------------------------------------------------------------------------- |
| Rust       | `src`, `rustPlatform`                                                            |
| Python     | `src`, `python`, `pyproject`, `extraRequirements`                                 |
| Go         | `src`                                                                            |
| JavaScript | `src`, `frameworkArgs`                                                            |

```nix
getArgs =
  { pkgs, ... }:
  {
    src = pkgs.fetchFromGitHub {
      owner = "Openmesh-Network";
      repo = "xnode-manager";
      tag = "v1.0.2";
      hash = "sha256-svxx9B3O6b6ILq0TrtabSfSgR6vYGIq1pFNaCm+sA10=";
    };
  };
```

## Tests

The tests of the builders assert the behavior of the override system and of the
custom outputs. They only inspect the evaluated outputs, they never build the
application:

```sh
nix flake check
```

The tests of the `crate2nix` implementation are only run in impure mode,
because the `Cargo.nix` file of the application is generated with an import
from derivation, which is only possible on the system of the machine that
builds the derivations:

```sh
nix flake check --impure
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
