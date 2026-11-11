{ inputs, lib, helpers }:
let
  inherit (helpers)
    mergeValues
    resolveOverrides
    defaultDevShellBuildInputs
    mkUpdate
    ;
in
{
  appBuilder =
    {
      system,
      pkgs,
      app,
      appArgs,
    }:
    let
      name = app.name;
      version = app.version;
      src = if app ? src then app.src else (appArgs.src or null);
      type =
        app.type or (
          if builtins.pathExists (src + "/uv.lock") then
            "uv"
          else if builtins.pathExists (src + "/poetry.lock") then
            "poetry"
          else
            ""
        );
      implementation = app.implementation or (if type == "uv" then "uv2nix" else "pyproject.nix");
      override = appArgs.override or { };
      python = appArgs.python or pkgs.python3;
      sourcePreference = appArgs.sourcePreference or "wheel";

      resolve =
        scope: defaults:
        resolveOverrides {
          inherit
            override
            scope
            implementation
            defaults
            ;
          specialArgs = helpers.implementationSpecialArgs.${implementation} or { };
        };

      devShell =
        let
          resolved = resolve "devshell" {
            shell = {
              buildInputs =
                (defaultDevShellBuildInputs { inherit pkgs; })
                ++ [ python ]
                ++ (
                  if type == "uv" then
                    [ pkgs.uv ]
                  else if type == "poetry" then
                    [ pkgs.poetry ]
                  else
                    [ ]
                );
            };
          };
        in
        pkgs.mkShell (
          mergeValues {
            prev = resolved.stepArgs.shell;
            next = resolved.genericArgs;
            extendLists = true;
          }
        );
    in
    (
      if implementation == "pyproject.nix" then
        let
          pyproject = pkgs.lib.importTOML (src + (appArgs.pyproject or "/pyproject.toml"));
          # Poetry projects can use either the legacy `[tool.poetry]` table or
          # PEP-621 `[project]` metadata. Prefer the PEP-621 metadata when it is
          # present, because Poetry 2 projects can contain both.
          loader =
            if type == "uv" then
              "loadUVPyproject"
            else if pyproject ? project then
              "loadPyproject"
            else if type == "poetry" || pyproject ? tool.poetry then
              "loadPoetryPyproject"
            else
              "loadPyproject";
          extraRequirements = appArgs.extraRequirements or [ ];
          baseProject = inputs.pyproject-nix.lib.project.${loader} {
            inherit pyproject;
            projectRoot = src;
          };
          finalDependencies =
            (builtins.map (
              requirement:
              (inputs.pyproject-nix.lib.project.loadRequirementsTxt {
                requirements =
                  let
                    processRequirements =
                      path:
                      let
                        parentFolder = builtins.dirOf path;
                        rawContent = builtins.readFile path;
                        perLine = pkgs.lib.splitString "\n" rawContent;
                        patchedLines = builtins.map (
                          line:
                          let
                            readFile = pkgs.lib.splitString "-r " line;
                          in
                          if line != "" && builtins.elemAt readFile 0 == "" then
                            processRequirements "${parentFolder}/${builtins.elemAt readFile 1}"
                          else
                            line
                        ) perLine;
                      in
                      builtins.concatStringsSep "\n" patchedLines;
                  in
                  processRequirements (src + "/${requirement}");
              }).dependencies.dependencies
            ) extraRequirements)
            ++ [ baseProject.dependencies.dependencies ];
          project = baseProject // {
            dependencies = baseProject.dependencies // {
              dependencies = builtins.concatLists finalDependencies;
            };
          };
          buildPythonPackage' =
            scope:
            let
              resolved = resolve scope {
                buildPythonPackage =
                  {
                    inherit version;
                    pname = name;
                    pythonRelaxDeps = true;
                    doCheck = scope == "check";
                  }
                  // (
                    if scope == "check" then
                      {
                        nativeCheckInputs = [ python.pkgs.pytestCheckHook ];
                      }
                    else
                      { }
                  );
              };
            in
            python.pkgs.buildPythonPackage (
              (inputs.pyproject-nix.lib.renderers.buildPythonPackage { inherit python project; })
              // (mergeValues {
                prev = resolved.stepArgs.buildPythonPackage;
                next = resolved.genericArgs;
                extendLists = true;
              })
            );
        in
        {
          check = buildPythonPackage' "check";
          package = buildPythonPackage' "package";
          extra = {
            inherit appArgs project;
          };
        }
      else if implementation == "uv2nix" then
        let
          workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = src; };
          overlay = workspace.mkPyprojectOverlay {
            inherit sourcePreference;
          };
          resolvedPackage = resolve "package" {
            pythonSet = { };
            venv = {
              venvIgnoreCollisions = [ "*" ];
            };
            application = { };
          };
          resolvedCheck = resolve "check" {
            pythonSet = { };
            venv = {
              venvIgnoreCollisions = [ "*" ];
            };
            application = { };
          };
          # Build the Python package set of a scope. The `check` scope only
          # builds a virtual environment for the tests, it does not build the
          # package a second time.
          mkPythonSet =
            resolved:
            (pkgs.callPackage inputs.pyproject-nix.build.packages {
              inherit python;
            }).overrideScope
              (
                pkgs.lib.composeManyExtensions [
                  inputs.pyproject-build-systems.overlays.wheel
                  overlay
                  (resolved.stepArgs.pythonSet.override or (final: prev: { }))
                ]
              );
          mkPackage =
            resolved:
            let
              pythonSet = mkPythonSet resolved;
              generic = resolved.genericArgs;
              package =
                if generic == { } then
                  pythonSet.${name}
                else
                  pythonSet.${name}.overrideAttrs (
                    old:
                    lib.filterAttrs (key: _: builtins.hasAttr key generic) (mergeValues {
                      prev = old;
                      next = generic;
                      extendLists = true;
                    })
                  );
              venv = (pythonSet.mkVirtualEnv "${name}-${version}-venv" workspace.deps.default).overrideAttrs (
                old: resolved.stepArgs.venv
              );
              application = (pkgs.callPackages inputs.pyproject-nix.build.util { }).mkApplication {
                inherit venv package;
              };
            in
            {
              inherit pythonSet venv package;
              result = application.overrideAttrs (old: resolved.stepArgs.application);
            };
          pythonPackage = mkPackage resolvedPackage;

          # Run the tests of the application instead of building the package a
          # second time. The check environment contains the project and all of
          # its dependency groups. `pytest` is taken from the selected
          # interpreter, the site-packages of the environment are added to
          # `PYTHONPATH` so that the tests can import the project.
          checkVenv =
            (
              (mkPythonSet resolvedCheck).mkVirtualEnv "${name}-${version}-check-venv" workspace.deps.all
            ).overrideAttrs (old: resolvedCheck.stepArgs.venv);
          check =
            pkgs.runCommand "${name}-check" {
              nativeBuildInputs = [
                checkVenv
                python.pkgs.pytest
              ];
              PYTHONPATH = "${checkVenv}/${python.sitePackages}";
            } ''
              cp -r ${src} source
              chmod -R u+w source
              cd source
              if [ -d tests ]; then
                # Exit code 5 means that no tests were collected.
                pytest || test $? -eq 5
              fi
              touch $out
            '';
        in
        {
          inherit check;

          package = pythonPackage.result;

          extra = {
            inherit
              appArgs
              overlay
              sourcePreference
              ;
            pythonSet = pythonPackage.pythonSet;
            venv = pythonPackage.venv;
          };
        }
      else
        builtins.throw "Unknown implementation ${implementation}"
    )
    // {
      inherit devShell;
      update = mkUpdate pkgs {
        inherit name;
        # `pyproject.nix` builds the package without a lock file, only
        # the package managers that write one can update the
        # dependencies of the application.
        command =
          if type == "uv" then
            "uv lock --upgrade"
          else if type == "poetry" then
            "poetry update"
          else
            "";
        runtimeInputs =
          if type == "uv" then
            [ pkgs.uv ]
          else if type == "poetry" then
            [ pkgs.poetry ]
          else
            [ ];
      };
      formatter =
        if type == "uv" then
          pkgs.writeShellApplication {
            name = "${name}-formatter";
            runtimeInputs = [ pkgs.ruff ];
            text = ''
              if [ "$#" -gt 0 ] && [ -d "$1" ]; then
                cd "$1"
              fi
              ruff format .
              ruff check --fix .
            '';
          }
        else if type == "poetry" then
          pkgs.writeShellApplication {
            name = "${name}-formatter";
            runtimeInputs = [ pkgs.black pkgs.isort ];
            text = ''
              if [ "$#" -gt 0 ] && [ -d "$1" ]; then
                cd "$1"
              fi
              black .
              isort .
            '';
          }
        else
          pkgs.writeShellApplication {
            name = "${name}-formatter";
            runtimeInputs = [ pkgs.black ];
            text = ''
              if [ "$#" -gt 0 ] && [ -d "$1" ]; then
                cd "$1"
              fi
              black .
            '';
          };
    };

  appProcess =
    app:
    let
      metadata =
        if app ? src then builtins.fromTOML (builtins.readFile (app.src + "/pyproject.toml")) else { };
      processed = {
        name = metadata.project.name or "python-app";
        version = metadata.project.version or "1.0.0";
      }
      // app;
    in
    processed;
}
