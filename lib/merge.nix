{ lib }:
let
  # Arguments that hold a list and can therefore be extended with a
  # function of their previous value.
  mergeableKeys = [
    "buildInputs"
    "buildInputs64"
    "checkInputs"
    "nativeBuildInputs"
    "nativeCheckInputs"
    "propagatedBuildInputs"
    "propagatedNativeBuildInputs"
    "testInputs"
    "patches"
    "makeFlags"
    "configureFlags"
    "buildFlags"
    "checkFlags"
    "installFlags"
  ];

  # Whether a value is a derivation. `lib.isDerivation` cannot be used
  # because it fails on values without a `type` attribute.
  isDerivation = value: builtins.isAttrs value && (value ? drvPath);

  # Merge `next` into `prev`. Attribute sets are merged recursively,
  # every other value of `next` overwrites the value of `prev`.
  # Functions of list arguments are applied to their previous value.
  # With `extendLists`, lists are concatenated instead of overwritten.
  #
  # Every key of `next` is considered, not only the keys that are present
  # in `prev`, so a function of an absent list argument is applied to an
  # empty list instead of leaking into the result.
  mergeValues =
    {
      prev,
      next,
      extendLists ? false,
    }:
    let
      mergeKey =
        key:
        let
          hasPrevious = builtins.hasAttr key prev;
          previous = if hasPrevious then prev.${key} else null;
          value = next.${key};
        in
        if
          builtins.isAttrs previous
          && builtins.isAttrs value
          && !(isDerivation previous)
          && !(isDerivation value)
        then
          mergeValues {
            prev = previous;
            next = value;
            inherit extendLists;
          }
        else if builtins.isFunction value && builtins.elem key mergeableKeys then
          let
            base = if hasPrevious then previous else [ ];
          in
          if builtins.isFunction base then value (base [ ]) else value base
        else if extendLists && builtins.isList previous && builtins.isList value then
          previous ++ value
        else
          value;
    in
    prev
    // builtins.listToAttrs (
      builtins.map (key: lib.nameValuePair key (mergeKey key)) (builtins.attrNames next)
    );

  # Build steps of every implementation. `shell` (the development shell)
  # is available for every implementation.
  implementationSteps = {
    crate2nix = [ "build" ];
    naersk = [ "buildPackage" ];
    crane = [
      "buildPackage"
      "buildDepsOnly"
      "cargoClippy"
      "cargoFmt"
      "cargoNextest"
    ];
    buildRustPackage = [ "buildPackage" ];
    "pyproject.nix" = [ "buildPythonPackage" ];
    uv2nix = [
      "pythonSet"
      "venv"
      "application"
    ];
    buildGoModule = [ "buildGoModule" ];
    buildNpmPackage = [ "buildNpmPackage" ];
  };

  # Arguments of an implementation that are handled by the implementation
  # itself and can therefore not be applied generically.
  implementationSpecialArgs = {
    crate2nix = {
      features = "build";
      crateOverrides = "build";
      runTests = "build";
      testCrateFlags = "build";
      testInputs = "build";
      testPreRun = "build";
      testPostRun = "build";
    };
    naersk = { };
    crane = { };
    buildRustPackage = { };
    "pyproject.nix" = { };
    uv2nix = {
      override = "pythonSet";
    };
    buildGoModule = { };
    buildNpmPackage = { };
  };

  commonSteps = [ "shell" ];

  # The build steps that are available in a scope. The development shell
  # only has the `shell` step, the other scopes have the steps of the
  # implementation.
  scopeSteps =
    scope: implementation:
    if scope == "devshell" then commonSteps else implementationSteps.${implementation} or [ ];

  # Resolve the override tree of a scope for an implementation.
  #
  # Returns the arguments of every step of the scope (`stepArgs`) and the
  # generic arguments that have to be applied by the implementation
  # (`genericArgs`).
  resolveOverrides =
    {
      override,
      scope,
      implementation,
      defaults,
      specialArgs,
    }:
    let
      knownSteps = scopeSteps scope implementation;
      layers = [
        (override.common.common or { })
        (override.common.${implementation} or { })
        (override.${scope}.common or { })
        (override.${scope}.${implementation} or { })
      ];
      isStep = slot: builtins.elem slot knownSteps;
      isSpecial = slot: builtins.hasAttr slot specialArgs;
      fold =
        acc: layer:
        let
          stepSlots = lib.filterAttrs (slot: _: isStep slot) layer;
          specialSlots = lib.filterAttrs (slot: _: isSpecial slot) layer;
          genericSlots = lib.filterAttrs (slot: _: !(isStep slot) && !(isSpecial slot)) layer;
          mergeStep =
            step: previous:
            let
              # `specialSlots` contains the values of the user's layer, not
              # the step names. The step a slot belongs to is stored in
              # `specialArgs`, so the slot has to be looked up there.
              special = lib.filterAttrs (slot: _: specialArgs.${slot} == step) specialSlots;
            in
            mergeValues {
              prev = mergeValues {
                prev = previous;
                next = special;
              };
              next = stepSlots.${step} or { };
            };
          newSteps = lib.filterAttrs (step: _: !(builtins.hasAttr step acc.stepArgs)) stepSlots;
          stepArgs =
            lib.mapAttrs (step: previous: mergeStep step previous) acc.stepArgs
            // lib.mapAttrs (step: _: mergeStep step { }) newSteps;
        in
        {
          stepArgs = stepArgs;
          genericArgs = mergeValues {
            prev = acc.genericArgs;
            next = genericSlots;
            extendLists = true;
          };
        };
      initial = {
        stepArgs = defaults;
        genericArgs = { };
      };
    in
    builtins.foldl' fold initial layers;

  # Normalize the arguments of an application.
  #
  # Only `getArgs.override` is supported. A top-level `override` on the
  # application is intentionally ignored.
  normalizeAppArgs =
    {
      pkgs,
      app ? { },
      appArgs ? { },
    }:
    let
      override = appArgs.override or { };
      env = appArgs.env or { };
      rpath = appArgs.rpath or [ ];
      src = if app ? src then app.src else (appArgs.src or null);
      normalized = appArgs // {
        inherit override env rpath;
      } // lib.optionalAttrs (src != null) { inherit src; };
    in
    {
      inherit
        override
        env
        rpath
        src
        ;
      appArgs = normalized;
    };

  # Recursively merge the results of every system.
  #
  # `lib.recursiveUpdate` stops only at non-attribute values, but a
  # derivation is an attribute set as well. Merging two derivations would
  # produce a hybrid derivation instead of letting the later one win, so
  # recursion also stops at derivations.
  combine =
    list:
    builtins.foldl' (
      lib.recursiveUpdateUntil (
        _: left: right:
        !(builtins.isAttrs left && builtins.isAttrs right) || isDerivation left || isDerivation right
      )
    ) { } list;
in
{
  inherit
    mergeableKeys
    isDerivation
    mergeValues
    implementationSteps
    implementationSpecialArgs
    commonSteps
    scopeSteps
    resolveOverrides
    normalizeAppArgs
    combine
    ;
}
