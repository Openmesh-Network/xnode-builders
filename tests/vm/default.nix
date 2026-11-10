{ pkgs, lib, defaultModule }:
let
  app = {
    name = "xnode-vm-test";
    version = "1.0.0";
    getArgs = _: { };
    module = { };
  };

  appBuilder =
    { pkgs, ... }:
    {
      package = pkgs.writeShellScriptBin "xnode-vm-test" ''
        echo started > "$STATE_DIRECTORY/marker"
        exec ${pkgs.coreutils}/bin/sleep infinity
      '';
      devShell = pkgs.mkShell { };
      formatter = pkgs.writeShellScriptBin "xnode-vm-test-formatter" "true";
      check = null;
      cacheDirectory = true;
    };
in
pkgs.testers.runNixOSTest {
  name = "xnode-builders-module";

  nodes.machine =
    { config, utils, pkgs, ... }:
    {
      imports = [
        (defaultModule {
          inherit app appBuilder;
          nixArgs = {
            inherit
              pkgs
              lib
              config
              utils
              ;
          };
        })
      ];

      services.xnode-vm-test.enable = true;
    };

  testScript = ''
    machine.wait_for_unit("xnode-vm-test.service")
    machine.wait_for_file("/var/lib/xnode-vm-test/marker")
    machine.succeed("getent passwd xnode-vm-test")
    machine.succeed("systemctl show -p NoNewPrivileges --value xnode-vm-test.service | grep -qx yes")
    machine.succeed("systemctl show -p CacheDirectory --value xnode-vm-test.service | grep -qx xnode-vm-test")
    machine.succeed("test -d /var/cache/xnode-vm-test")
  '';
}
