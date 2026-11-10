{ lib }:
{ pkgs }:
{
  package,
  env ? { },
  rpath ? [ ],
  passthru ? { },
}:
let
  hasEnv = env != { };
  hasRpath = rpath != [ ];
  rpathString = lib.concatStringsSep ":" (builtins.map toString rpath);
  envFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (
      key: value: "--set-default ${lib.escapeShellArg key} ${lib.escapeShellArg (toString value)}"
    ) env
  );
in
# `symlinkJoin` works for every derivation, not only for stdenv-based
# derivations, so the wrapper can also be applied to e.g. `mkApplication`
# outputs. The binaries are copied out of the joined tree before they are
# wrapped, so the store paths of the original package are never modified.
pkgs.symlinkJoin {
  name = "${package.name or package.pname or "app"}-wrapped";
  paths = [ package ];
  nativeBuildInputs = [ pkgs.makeWrapper ] ++ lib.optionals hasRpath [ pkgs.patchelf pkgs.binutils ];
  passthru = (package.passthru or { }) // passthru // { unwrapped = package; };
  meta = package.meta or { };
  postBuild = ''
    if [ -d "$out/bin" ]; then
      for bin in "$out/bin"/*; do
        [ -e "$bin" ] || continue

        # `symlinkJoin` links the binaries of the package, `wrapProgram`
        # and `patchelf` need a writable copy.
        if [ -L "$bin" ]; then
          target="$(readlink -f "$bin")"
          rm "$bin"
          cp -L "$target" "$bin"
          chmod +w "$bin"
        fi

        [ -f "$bin" ] || continue
        [ -x "$bin" ] || continue

        ${lib.optionalString hasRpath ''
          # Only touch ELF binaries with a dynamic section. Shell scripts and
          # static binaries have nothing to patch. This runs before
          # `wrapProgram`, which moves the binary out of the way, so the
          # runpath is added to the real binary and not to the wrapper.
          if readelf -d "$bin" >/dev/null 2>&1; then
            patchelf --add-rpath ${lib.escapeShellArg rpathString} "$bin"
          fi
        ''}

        ${lib.optionalString hasEnv ''
          wrapProgram "$bin" ${envFlags}
        ''}
      done
    fi
  '';
}
